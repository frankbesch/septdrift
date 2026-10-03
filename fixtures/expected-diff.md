# Expected diff

Five checks flip, eight remain unchanged, and the recording diff exits 1.

## Inputs and header

Here, side-a and side-b mean verified recordings generated from the corresponding fixtures using cases/day2.yaml.
Both recordings contain eight results and identical casesSHA256 values.
No request changes, unpaired cases, added checks, or removed checks occur.

Raw FixtureBackend files lack receipt headers, trailers, and hashes.
Passing those fixture files directly to diff violates §5 preconditions and exits 4.

| Header field | A | B |
|---|---|---|
| backend | fixture | fixture |
| chip | Recorded host value; fixtures do not specify it | Recorded host value; fixtures do not specify it |
| osBuild | Recorded host value; fixtures do not specify it | Recorded host value; fixtures do not specify it |
| distinct assetIDs | ["fixture-model-1"] | ["fixture-model-1"] |

## Check rates

Each rate equals passing repetitions divided by all repetitions for that check.
Errors remain in check denominators.
Delta equals rateB minus rateA.

| caseID | Check identity (name, arg) | rateA | rateB | Delta | Class |
|---|---|---|---|---|---|
| afe-no-context | contains: "Authorization for Expenditure" | 1/1 = 1 | 0/1 = 0 | -1 | flip |
| afe-no-context | max_wall_ms: 3000 | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| afe-with-context | contains: "Authorization for Expenditure" | 1/1 = 1 | 0/1 = 0 | -1 | flip |
| afe-with-context | max_wall_ms: 3000 | 1/1 = 1 | 0/1 = 0 | -1 | flip |
| ordered-json | json_field_equals: {"field":"kind","value":"request"} | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| ordered-json | json_field_equals: {"field":"count","value":3} | 1/1 = 1 | 0/1 = 0 | -1 | flip |
| ordered-json | json_field_equals: {"field":"approved","value":true} | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| repeat-ready | contains: "Ready for review" | 3/3 = 1 | 2/3 | -1/3 | flip |
| repeat-ready | max_wall_ms: 1500 | 3/3 = 1 | 3/3 = 1 | 0 | unchanged |
| guardrail-error | expect_error: "guardrail" | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| status-summary | regex: '^Status: ready\.$' | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| status-summary | not_contains: "blocked" | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |
| status-summary | max_output_tokens: 40 | 1/1 = 1 | 1/1 = 1 | 0 | unchanged |

The repeated contains outcomes are [pass, pass, pass] in A and [pass, pass, fail] in B.
The repeat check is a flip because A passes every repetition.
It is not a degrade under §5.

The context error makes both afe-with-context checks fail with reason "error" under §4.2.
Its wallMs value meets the limit, but the error rule takes precedence.
Its content becomes empty under §2; all other fixture fields remain identical.
The guardrail error passes expect_error and still contributes to error-kind counts.

| Class | Count |
|---|---:|
| flip | 5 |
| degrade | 0 |
| fix | 0 |
| unchanged | 8 |
| total | 13 |

## Timing and tokens

Medians exclude every error result, including the expected guardrail error.
These calculations use the arithmetic mean of the middle values for even sample sizes.

| Metric | A: seven non-error results | B: six non-error results |
|---|---|---|
| Sorted wallMs | 600, 700, 800, 900, 1000, 1100, 1200 | 600, 700, 800, 1000, 1100, 1200 |
| Median wallMs | Fourth value = 900 | (800 + 1000)/2 = 900 |
| Sorted tokensOut | 12, 12, 12, 15, 18, 20, 32 | 12, 12, 12, 15, 18, 20 |
| Median tokensOut | Fourth value = 15 | (12 + 15)/2 = 13.5 |

The status-summary check uses tokensOut = 18, which already includes tokensReasoning = 12.

## Error-kind counts

| Error kind | A | B |
|---|---:|---:|
| guardrail | 1 | 1 |
| refusal | 0 | 0 |
| unsupported | 0 | 0 |
| context | 0 | 1 |
| unavailable | 0 | 0 |
| other | 0 | 0 |
| Total errors | 1 | 2 |

## Exit code and execution

The recording diff exits 1 because flips = 5 > 0.
Neither --fail-on-fix nor --allow-request-drift is needed.

Generate recordings before running the diff:

    septdrift run cases/day2.yaml --backend fixture --fixtures fixtures/side-a.jsonl --out side-a
    septdrift run cases/day2.yaml --backend fixture --fixtures fixtures/side-b.jsonl --out side-b
    septdrift diff side-a side-b
