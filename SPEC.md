# septdrift — SPEC v0.3

A CLI that runs declared cases against a language-model backend, writes receipt-shaped
records, scores them against declared checks, and diffs two recordings. Fixture mode needs
no model. Live mode uses Apple's on-device model through FoundationModels. Harness minimum is
macOS 27 (for `Response.usage`); the framework itself is macOS 26+.

## 1. Case file (`cases/*.yaml` or `.json`)
A file is a list of cases.

```yaml
- id: afe-no-context            # required, unique across the whole load, [a-z0-9-]+
  instructions: "..."           # optional; LanguageModelSession(instructions:)
  context: "..."                # optional; prepended to the prompt as "Context:\n<context>\n\n"
  prompt: "..."                 # required
  format: text | json           # default text; json => guided generation with the schema below
  schema:                       # required iff format: json. ORDERED list (property order is part of the request)
    - {name: kind, kind: string, description: "document type", optional: false}
    - {name: amount, kind: double}
  options:                      # optional; GenerationOptions
    temperature: 0.0            # default: framework default (record "default" when absent)
    max_response_tokens: 200
  repeat: 1                     # optional, 1..20; each repetition is its own record, fresh session
  checks:                       # required, at least one; identity = (name, arg)
    - contains: "..."           # case-sensitive substring of content
    - not_contains: "..."
    - regex: "..."              # NSRegularExpression, unanchored
    - json_field_equals: {field: kind, value: "AFE"}   # json only; typed by the schema kind (see §4); a YAML scalar value (3, true) is accepted and stringified
    - json_field_in: {field: kind, values: ["AFE", "PO"]}   # json only; label set, each value typed by the schema kind
    - json_field_range: {field: amount, min: 0.5, max: 0.9}   # json only; int or double field; inclusive; min, max, or both
    - json_field_rank: {field: level, ladder: [none, low, medium, high], min: medium}   # json only; string field; ladder ordered lowest to highest; inclusive; min, max, or both
    - max_wall_ms: 3000         # inclusive
    - max_output_tokens: 80     # inclusive; tokensOut = output.totalTokenCount (reasoning included)
    - expect_error: guardrail | refusal | unsupported | context | unavailable | any
```
Validation errors (missing id/prompt/checks, empty checks, duplicate id, bad id, schema without json,
json without schema, unknown check, invalid regex, json_field_equals on text, repeat out of 1...20,
a malformed json_field_in / json_field_range / json_field_rank (text format, undeclared field, wrong
field kind, unknown key, empty or repeated values, a value that does not fit the kind, no bound, min
above max, a bound off the ladder, a ladder under two rungs or with a repeated rung),
expect_error combined with any other check on the same case) fail the whole run before any model
call, exit 3.

## 2. Backend
```swift
protocol Backend: Sendable {
  var name: String { get }                      // "system" | "fixture"
  func respond(to case: Case, rep: Int) async throws -> Result
}
struct Result: Sendable {
  var content: String            // text, or the JSON rendering for format: json ("" on error)
  var wallMs: Int                // respond() call only; excludes session creation and the run's warm-up
  var tokensIn: Int?             // usage.input.totalTokenCount; nil when unreported
  var tokensCached: Int?         // usage.input.cachedTokenCount
  var tokensOut: Int?            // usage.output.totalTokenCount (includes reasoning)
  var tokensReasoning: Int?      // usage.output.reasoningTokenCount
  var assetIDs: [String]         // from THIS response's transcript entries only; [] when unknown
  var error: ErrorKind?          // typed; content "" then
  var errorDetail: String?       // the thrown error's description
}
enum ErrorKind: String, Sendable { case guardrail, refusal, unsupported, context, unavailable, other }
```
Execution semantics, declared: one fresh `LanguageModelSession` per (case, rep); cases run serially
in file order; no retries; no deadline in v0.3. Warm-up (v0.3.7): `run --backend system` makes one
unrecorded call before the first case (a fixed text case, id `warm-up`, "Reply with the single word
ready."), after the header, so the first recorded call does not carry the model's cold start; `run`
prints its wall time as `warm-up - -/- <ms>ms (not recorded)`. `--no-warm-up` skips it; a fixture run
never warms up. The recording does not say whether a warm-up ran; the run's stdout does.
- `SystemBackend`: `SystemLanguageModel.default`; availability checked once before the run (exit 2 if
  unavailable, reason printed). A later per-call unavailability becomes `error: unavailable` on that
  record. `LanguageModelError` (macOS 27+, the non-deprecated type) cases map: guardrailViolation→guardrail,
  refusal→refusal, unsupportedCapability/unsupportedTranscriptContent/unsupportedGenerationGuide/
  unsupportedLanguageOrLocale→unsupported, contextSizeExceeded→context, rateLimited/timeout→other,
  everything else→other. The deprecated `LanguageModelSession.GenerationError` is still caught and mapped
  for the deprecated path: guardrailViolation→guardrail, refusal→refusal, unsupportedGuide/
  unsupportedLanguageOrLocale→unsupported, exceededContextWindowSize→context, assetsUnavailable→unavailable,
  everything else→other. Any other thrown error is `other` with measured `wallMs` (never the zero fallback).
  A text answer that is a refusal in prose is NOT an error; declare `not_contains` for it in the case.
- `FixtureBackend`: `--fixtures <file.jsonl>`; lines `{caseID, rep, content, wallMs, tokensIn?, tokensCached?,
  tokensOut?, tokensReasoning?, assetIDs?, error?, errorDetail?}`; lookup by (caseID, rep) with rep 0-based; missing ⇒
  `error: other, errorDetail: "no fixture"`; a duplicate (caseID, rep) in the fixture file ⇒ exit 3. Deterministic. This is the CI path.

## 3. Recording (`receipt/0.2`), JSONL
Three record types share a file: one `run` header (seq 0), N `result` records, one `end` trailer.

Canonical bytes (the only thing hashed): JSON object, keys sorted (byte order), UTF-8, no whitespace,
`/` unescaped, numbers as integers where integral, `null` for absent optionals, no unknown fields.
Numbers (v0.3.8): an integer literal is exact across the Int64 range and never passes through a Double;
an integer outside Int64 is not canonical. A double that is integral and below 2^53 renders as an
integer; any other finite double renders as its shortest round-trip form. Non-finite values are
rejected at parse and at case load.
`sha256` = SHA-256 over the canonical bytes of the record with `sha256: ""`. `prev` = the previous
record's `sha256` VALUE (not its line bytes). No newline is hashed. Ten fixed hash vectors ship in the
tests so a second implementation can match byte for byte.

| field | run | result | end |
|---|---|---|---|
| schema | "receipt/0.2" | same | same |
| type | "run" | "result" | "end" |
| runID, seq, ts | ✓ | ✓ | ✓ |
| host {os, osBuild, chip, name} | ✓ | | |
| backend | ✓ | | |
| casesSHA256 | sha256 of canonical JSON of the loaded `[Case]` | | |
| expected | [{caseID, repeat}] | | |
| caseID, rep | | ✓ (rep is 0-based, 0..repeat-1) | |
| requestSHA256 | | sha256 of canonical JSON of {instructions, context, prompt, format, schema, options}; absent optionals are `null` (options absent ⇒ `null`, never "default") | |
| content, error, errorDetail, wallMs | | ✓ | |
| tokens {in, cached, out, reasoning} | | ✓ (nulls when unreported) | |
| assetIDs | | ✓ | |
| checks [{name, arg, pass, reason}] | | ✓ | |
| count | | | number of result records |
| prev, sha256 | ✓ (header prev = "") | ✓ | ✓ |

`verify <file>`: recomputes every hash, the chain, that seq is 0..n contiguous, that the trailer exists
and `count` equals the result records present, that every `expected` (caseID, rep) appears exactly
once, and that every record has exactly the fields and types of the table above (v0.3.4). Prints `OK n results` or the first failure with seq; exit 0/1. A file without a trailer is
"incomplete", exit 1; so is a file whose final record was cut short before its newline (v0.3.8). A
malformed final record that ends with a newline stays "non-canonical". Limitation, stated in the README: an unsigned chain proves internal consistency,
not origin; anyone can rewrite a whole file. Signing is a non-goal in v0.3.

`run` writes the header before the first model call and the trailer after the last; on crash the file is
incomplete by construction.

## 4. Checks
Pure functions `(Check, Case, Result) -> Outcome {pass, reason}`. Rules, in order:
1. `expect_error: K` passes iff `result.error == K` (or any non-nil for `any`); fails "no error" / "wrong error: X".
2. Any other check on a result with `error != nil` fails "error".
3. `contains` / `not_contains`: substring of `content`. Reasons "not found" / "found".
4. `regex`: unanchored; invalid pattern cannot reach here (validation), evaluator still returns fail "invalid regex".
5. `json_field_equals`: parse `content` as a JSON object (fail "not json object"); field missing ⇒ "missing";
   compare by the schema kind of `field`: string ⇒ exact; int ⇒ integer equality; double ⇒ equality after
   `Double(value)`; bool ⇒ `true`/`false` literal. Reason "expected X got Y".
6. `max_wall_ms`: `wallMs <= limit`. Independent of tokens.
7. `max_output_tokens`: `tokensOut <= limit`; `tokensOut == nil` ⇒ fail "unreported".
8. `json_field_in`: parse and field rules as in 5; passes iff the field equals one of `values` under the
   schema kind. Reason "expected one of A, B got Y". arg = `field=` + canonical JSON array of the values.
9. `json_field_range`: the field must be a JSON number (fail "not a number: Y"), integral on an int field
   (fail "not an integer: Y"); passes iff `min <= value <= max` for each bound given. Reasons "Y < min" /
   "Y > max". arg = `field=[min,max]`, `null` for an open end.
10. `json_field_rank`: the field must be a string that is a rung of `ladder`, compared case-sensitively
   (fail "off ladder: Y"); passes iff its position is within the bounds given. Reasons "Y < min" / "Y > max".
   A fail-closed value such as `needs_review` is off the ladder, so it fails every threshold.
   arg = `field=` + canonical JSON of `{ladder, max, min}`.

## 5. Diff
`diff <a.jsonl> <b.jsonl> [--json] [--fail-on-fix] [--allow-request-drift]`
Preconditions (exit 4 with reason if violated): both files verify; both complete; `casesSHA256` equal, or
`--allow-request-drift` given (then pairs whose `requestSHA256` differ are listed as "request changed" and
excluded from flips).
- Pair by caseID. Unpaired ⇒ "only in A/B", not a flip.
- Per (caseID, check identity (name,arg)): pass rate over reps on each side, `rateA`, `rateB`.
  **flip** = rateA == 1.0 and rateB < 1.0. **degrade** = rateB < rateA otherwise (reported, no exit).
  **fix** = rateA < 1.0 and rateB == 1.0. **improved** = rateB > rateA with rateB < 1.0 (reported, no exit).
  Checks present on one side only ⇒ "check added/removed".
- Scorecard (stdout, `--json`): header with backend, chip, osBuild, distinct assetIDs per side; table
  caseID · check · rateA · rateB · Δ; medians of wallMs and tokensOut over non-error results per side;
  counts flips/degrades/fixes/unchanged/improved/added/removed, one per row, so they sum to the rows
  (unchanged = both sides present and rateA == rateB); error-kind counts per side.
  Median over an even count = mean of the two middle values, rendered as an integer rounded half up.
- Exit 1 if flips > 0 (`--fail-on-fix` adds fixes), else 0.

## 6. CLI
```
septdrift run <cases-path> --backend system|fixture [--fixtures file] [--out file] [--force] [--no-hostname] [--no-warm-up]
septdrift verify <file>
septdrift diff <a> <b> [--json] [--fail-on-fix] [--allow-request-drift]
septdrift cases <cases-path>        # validate + list
```
`<cases-path>`: file or directory (`*.yaml|*.yml|*.json`, sorted by filename). Default `--out`:
`recordings/<backend>-<osBuild>-<yyyymmdd-HHmmss>-<runID8>.jsonl`; an existing `--out` ⇒ exit 4 unless
`--force`. `run` exits 0 when it completes, regardless of check outcomes or recorded errors (diff judges);
2 only when the backend is unavailable before the run.
Exit codes: 0 ok · 1 flips · 2 model unavailable · 3 validation · 4 I/O or incompatible inputs.
An input that cannot be read (case file, fixture file, either diff side) is exit 4; a readable input
that is wrong is exit 3 (v0.3.8). `run` reads the host facts by absolute tool path (`/usr/bin/sw_vers`,
`/usr/sbin/sysctl`, `/bin/hostname`); a launch failure, nonzero status or empty output is exit 4.
`diff` reads each side once and verifies and scores those same bytes.

## 7. Tests (Swift Testing, `scripts/test.sh`, zero live calls)
- Case parsing: valid, each validation error, directory ordering, ordered schema, options.
- Checks: every rule above, pass and fail; typed equality per kind; expect_error each kind; error short-circuit.
- Recorder: ten fixed hash vectors; chain over header + 3 results + trailer; content byte tamper ⇒ seq named;
  non-canonical line (whitespace) ⇒ "non-canonical" at seq; truncated tail ⇒ "incomplete"; missing expected pair.
- Diff: flip, degrade, fix, unchanged, unpaired, check added/removed, request drift excluded, incompatible
  cases hash ⇒ exit 4, incomplete input ⇒ exit 4.
- Fixture backend: end-to-end `run` → `verify` → `diff` on two fixture files differing on one case, with
  per-rep responses and one typed error.

## 8. Non-goals (v0.3)
Streaming, tool calls, PCC/MLX/Claude backends, Evaluations framework, LLM-as-judge or semantic checks,
numeric tolerances and label sets (week 2), deadlines/cancellation, signing, GUI.

## Amendment log
- v0.3.8 (09-30, week 2, Codex code review 0602 #4, #5, #8, #14, #18, #19): exact integers in canonical parse and in int checks; a cut-short final record is "incomplete"; `diff` verifies and scores one byte snapshot per side; unreadable inputs exit 4; host capture by absolute path with failures propagated. All eight deferred Codex items are now closed.
- v0.3.7 (09-30, week 2): unrecorded warm-up call on `run --backend system`, `--no-warm-up` to skip; §2 and §6. No record or header field changes, so every recording keeps verifying and `casesSHA256` is unchanged.
- v0.3.6 (09-29, week 2): the `counts:` line and `--json` counts gain `improved`, `added` and `removed`, appended after `unchanged`, so the counts sum to the rows. The first four fields keep their order and text. Exit rules are unchanged.
- v0.3.5 (09-29, week 2): three checks added, `json_field_in` (label set), `json_field_range` (numeric bounds) and `json_field_rank` (ordinal ladder); §1 grammar and §4 rules 8–10. Existing cases and their `casesSHA256` are unchanged.
- v0.3.4 (09-29, week 2, Codex code review 0602 #1 and #7): `verify` enforces the §3 table strictly. Each record carries exactly its fields, with the stated JSON types and explicit nulls; `error` is null or a known error kind. A violation fails as `missing field x`, `unknown field x` or `bad field x`, with the seq. Each check identity (name, arg) appears once per result record, and every rep of a case carries the same checks in the same order.
- v0.3.3 (09-22, day 5, Codex code review 0602): LanguageModelError mapped; GenerationError kept for the deprecated path; any other thrown error is `other` with measured wallMs.
- v0.3.2 (09-22, day-2 returns): header prev = ""; requestSHA256 nulls for absent options; SystemBackend maps the deprecated `GenerationError` cases (macOS 27 deprecates it for `LanguageModelError`; migration is a week-2 item); verify ignores blank lines.
- v0.3.1 (09-22, Codex fixture keying 0154): rep 0-based stated; duplicate fixture key ⇒ exit 3; even-count median rule; unchanged defined; scalar values in json_field_equals accepted.
- v0.3 (09-22, Codex review 0144 triaged): canonical bytes + hash vectors; requestSHA256 replaces NUL-join;
  run header/trailer + expected membership + completeness; check identity (name,arg); per-check pass rates
  with flip/degrade/fix; typed errors + expect_error; typed json equality by schema kind; ordered schema;
  GenerationOptions; fixture per-rep + errors; session/timing semantics declared; --out collision policy;
  run exit policy; tokensOut definition; assetIDs from this response only; unsigned-chain limitation stated.
  Deferred to week 2: tolerances, label sets, semantic refusal detection. Rejected: none.
