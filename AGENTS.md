# AGENTS.md — how an agent should use septdrift

septdrift catches drift in Apple Foundation Models features across OS
updates: declared cases → receipt-shaped recordings → scored checks → a diff
of two recordings that exits 1 on a flip. It also runs with no model at all
through a fixture backend, which is the CI path.

## Commands

```bash
septdrift run <cases-path> --backend system|fixture [--fixtures f.jsonl] [--out r.jsonl] [--force] [--no-hostname] [--no-warm-up]
septdrift verify <recording.jsonl>
septdrift diff <a.jsonl> <b.jsonl> [--json] [--fail-on-fix] [--allow-request-drift]
septdrift cases <file-or-dir>        # validate case files and list what they declare
```

Build: `swift build -c release` (macOS 27+, Swift 6, Command Line Tools
suffice). Tests: `./scripts/test.sh` (fixture backend only).

## Exit codes

| code | meaning |
| --- | --- |
| 0 | ok (for `diff`: no flips) |
| 1 | flips (`diff`), or a broken or incomplete chain (`verify`: a file without its `end` trailer is "incomplete") |
| 2 | model unavailable (`--backend system` with Apple Intelligence off) |
| 3 | validation error (bad case file, duplicate fixture key) |
| 4 | I/O or incompatible inputs (an input file that cannot be read, existing `--out` without `--force`, differing `casesSHA256`) |

`run` exits 0 whenever it completes; check outcomes are judged by `diff`.

## For an agent

- To prove a change to cases or fixtures: `cases` on the directory, then a
  fixture `run`, `verify`, and a self-`diff` (expect `flips=0`). Quote the
  `counts:` line and the exit code in your receipt.
- A live recording (`--backend system`) is only meaningful on the target
  Mac; its header names chip, OS build, and model asset ids. Do not record
  live from a CI runner.
- Checks available: `contains`, `not_contains`, `regex`, `json_field_equals`
  (typed by the declared schema), `json_field_in` (label set),
  `json_field_range` (inclusive numeric bounds), `json_field_rank` (inclusive
  bounds on an ordered string ladder), `max_wall_ms`, `max_output_tokens`,
  `expect_error`. A value off the ladder fails `json_field_rank`, so a
  fail-closed value such as `needs_review` never passes a threshold.
- Case ids are `[a-z0-9-]+` and unique across the whole directory. Adding a
  case changes `casesSHA256`, so a diff against an older recording needs
  `--allow-request-drift` or a fresh baseline.
- The hash chain is unsigned: `verify` proves internal consistency, not
  origin. Do not describe a recording as tamper-proof.
- Fixture lines are `{caseID, rep, content, wallMs, tokensIn?, tokensOut?, assetIDs?, error?}`
  looked up by `(caseID, rep)`, rep 0-based. Put a model or backend id in
  `assetIDs` so `diff` can attribute a flip.

Full format and semantics: [SPEC.md](SPEC.md). Cases: `cases/*.yaml`.
