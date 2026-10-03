// SPEC §7 — checks: every rule in SPEC §4, pass and fail.
import Testing
@testable import SeptdriftCore

@Suite("ChecksTests")
struct ChecksTests {

    /// A text case; only `checks` matters for `evaluateAll`.
    private func textCase(_ checks: [Check] = [.contains("x")]) -> Case {
        Case(id: "text-case", prompt: "p", checks: checks)
    }

    /// A json case carrying the schema that types `json_field_equals`.
    private func jsonCase(
        _ fields: [SchemaField],
        checks: [Check] = [.contains("x")]
    ) -> Case {
        Case(id: "json-case", prompt: "p", format: .json, schema: fields, checks: checks)
    }

    private func result(
        _ content: String,
        wallMs: Int = 100,
        tokensOut: Int? = 10,
        error: ErrorKind? = nil
    ) -> Result {
        Result(content: content, wallMs: wallMs, tokensOut: tokensOut, error: error)
    }

    private func evaluate(_ check: Check, _ result: Result, in aCase: Case? = nil) -> Outcome {
        Checks.evaluate(check, in: aCase ?? textCase(), on: result)
    }

    // MARK: contains / not_contains

    @Test func containsPasses() {
        #expect(evaluate(.contains("AFE"), result("the AFE total")) == Outcome(pass: true))
    }

    @Test func containsIsCaseSensitive() {
        let outcome = evaluate(.contains("AFE"), result("the afe total"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "not found")
    }

    @Test func notContainsPasses() {
        #expect(evaluate(.notContains("AFE"), result("nothing here")).pass)
    }

    @Test func notContainsFails() {
        let outcome = evaluate(.notContains("AFE"), result("an AFE"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "found")
    }

    // MARK: regex

    @Test func regexPassesUnanchored() {
        #expect(evaluate(.regex("[0-9]{3}"), result("code 412 ok")).pass)
    }

    @Test func regexFails() {
        let outcome = evaluate(.regex("^[0-9]+$"), result("code 412 ok"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "no match")
    }

    @Test func regexInvalidPattern() {
        let outcome = evaluate(.regex("[unterminated"), result("anything"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "invalid regex")
    }

    // MARK: json_field_equals, typed by the schema kind

    private var afeSchema: [SchemaField] {
        [
            SchemaField(name: "kind", kind: .string, description: "document type"),
            SchemaField(name: "amount", kind: .double),
            SchemaField(name: "count", kind: .int),
            SchemaField(name: "approved", kind: .bool)
        ]
    }

    @Test func jsonStringFieldEquals() {
        let aCase = jsonCase(afeSchema)
        #expect(evaluate(.jsonFieldEquals(field: "kind", value: "AFE"),
                         result(#"{"kind":"AFE","amount":1.5}"#), in: aCase).pass)
    }

    @Test func jsonStringFieldMismatchReason() {
        let outcome = evaluate(.jsonFieldEquals(field: "kind", value: "AFE"),
                               result(#"{"kind":"PO"}"#), in: jsonCase(afeSchema))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "expected AFE got PO")
    }

    @Test func jsonStringKindRejectsANumber() {
        let outcome = evaluate(.jsonFieldEquals(field: "kind", value: "123"),
                               result(#"{"kind":123}"#), in: jsonCase(afeSchema))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "expected 123 got 123")
    }

    @Test func jsonIntFieldEquals() {
        let aCase = jsonCase(afeSchema)
        #expect(evaluate(.jsonFieldEquals(field: "count", value: "42"),
                         result(#"{"count":42}"#), in: aCase).pass)
        let outcome = evaluate(.jsonFieldEquals(field: "count", value: "43"),
                               result(#"{"count":42}"#), in: aCase)
        #expect(outcome.pass == false)
        #expect(outcome.reason == "expected 43 got 42")
    }

    @Test func jsonIntKindRejectsANonInteger() {
        let aCase = jsonCase(afeSchema)
        #expect(evaluate(.jsonFieldEquals(field: "count", value: "42"),
                         result(#"{"count":42.5}"#), in: aCase).pass == false)
    }

    @Test func jsonDoubleFieldEqualsAfterDoubleParse() {
        let aCase = jsonCase(afeSchema)
        #expect(evaluate(.jsonFieldEquals(field: "amount", value: "1.5"),
                         result(#"{"amount":1.5}"#), in: aCase).pass)
        // 1.0 and 1 are the same double; JSONSerialization renders 1.0 as "1".
        #expect(evaluate(.jsonFieldEquals(field: "amount", value: "1"),
                         result(#"{"amount":1.0}"#), in: aCase).pass)
        #expect(evaluate(.jsonFieldEquals(field: "amount", value: "1.0"),
                         result(#"{"amount":1.0}"#), in: aCase).pass)
        #expect(evaluate(.jsonFieldEquals(field: "amount", value: "2"),
                         result(#"{"amount":1.0}"#), in: aCase).pass == false)
    }

    @Test func jsonBoolFieldEquals() {
        let aCase = jsonCase(afeSchema)
        let content = #"{"approved":true}"#
        #expect(evaluate(.jsonFieldEquals(field: "approved", value: "true"),
                         result(content), in: aCase).pass)
        #expect(evaluate(.jsonFieldEquals(field: "approved", value: "false"),
                         result(#"{"approved":false}"#), in: aCase).pass)
        let outcome = evaluate(.jsonFieldEquals(field: "approved", value: "1"),
                               result(content), in: aCase)
        #expect(outcome.pass == false)
        #expect(outcome.reason == "expected 1 got true")
    }

    @Test func jsonNotAnObject() {
        let outcome = evaluate(.jsonFieldEquals(field: "kind", value: "AFE"),
                               result("plain text, not json"), in: jsonCase(afeSchema))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "not json object")
    }

    @Test func jsonArrayIsNotAnObject() {
        let outcome = evaluate(.jsonFieldEquals(field: "kind", value: "AFE"),
                               result(#"[{"kind":"AFE"}]"#), in: jsonCase(afeSchema))
        #expect(outcome.reason == "not json object")
    }

    @Test func jsonMissingField() {
        let outcome = evaluate(.jsonFieldEquals(field: "amount", value: "10"),
                               result(#"{"kind":"AFE"}"#), in: jsonCase(afeSchema))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "missing")
    }

    // MARK: wall time and tokens

    @Test func maxWallMsPassesInclusive() {
        #expect(evaluate(.maxWallMs(3000), result("x", wallMs: 3000)).pass)
    }

    @Test func maxWallMsFails() {
        let outcome = evaluate(.maxWallMs(3000), result("x", wallMs: 3500))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "3500 > 3000")
    }

    @Test func maxOutputTokensPassesInclusive() {
        #expect(evaluate(.maxOutputTokens(80), result("x", tokensOut: 80)).pass)
    }

    @Test func maxOutputTokensFails() {
        let outcome = evaluate(.maxOutputTokens(80), result("x", tokensOut: 120))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "120 > 80")
    }

    @Test func maxOutputTokensUnreported() {
        let outcome = evaluate(.maxOutputTokens(80), result("x", tokensOut: nil))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "unreported")
    }

    // MARK: expect_error (SPEC §4.1)

    @Test func expectErrorMatchesTheKind() {
        let errored = Result(content: "", wallMs: 5, error: .guardrail, errorDetail: "blocked")
        #expect(evaluate(.expectError(.guardrail), errored).pass)
    }

    @Test func expectErrorWrongKind() {
        let errored = Result(content: "", wallMs: 5, error: .refusal)
        let outcome = evaluate(.expectError(.guardrail), errored)
        #expect(outcome.pass == false)
        #expect(outcome.reason == "wrong error: refusal")
    }

    @Test func expectErrorNoError() {
        let outcome = evaluate(.expectError(.guardrail), result("fine"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "no error")
    }

    @Test func expectErrorAnyAcceptsEveryKind() {
        for kind in ErrorKind.allCases {
            let errored = Result(content: "", wallMs: 1, error: kind)
            #expect(evaluate(.expectError(nil), errored).pass)
        }
        let outcome = evaluate(.expectError(nil), result("fine"))
        #expect(outcome.pass == false)
        #expect(outcome.reason == "no error")
    }

    @Test func expectErrorEachKind() {
        for kind in ErrorKind.allCases {
            let errored = Result(content: "", wallMs: 1, error: kind)
            #expect(evaluate(.expectError(kind), errored).pass)
        }
    }

    // MARK: error short-circuit (SPEC §4.2)

    @Test func errorResultFailsEveryOtherCheck() {
        let errored = Result(content: "", wallMs: 5, tokensOut: 1, error: .guardrail,
                             errorDetail: "guardrailViolation")
        let checks: [Check] = [
            .contains("anything"),
            .notContains("anything"),
            .regex("."),
            .maxWallMs(10_000),
            .maxOutputTokens(10_000)
        ]
        let outcomes = Checks.evaluateAll(textCase(checks), on: errored)
        #expect(outcomes.count == checks.count)
        #expect(outcomes.allSatisfy { $0.pass == false && $0.reason == "error" })
    }

    @Test func errorResultFailsJSONFieldEquals() {
        let errored = Result(content: "", wallMs: 5, error: .context)
        let aCase = jsonCase(afeSchema)
        let outcome = evaluate(.jsonFieldEquals(field: "kind", value: "AFE"), errored, in: aCase)
        #expect(outcome.pass == false)
        #expect(outcome.reason == "error")
    }

    // MARK: evaluateAll

    @Test func evaluateAllPreservesCaseOrder() {
        let checks: [Check] = [.contains("hello"), .contains("nope"), .maxWallMs(100), .maxOutputTokens(5)]
        let outcomes = Checks.evaluateAll(
            textCase(checks),
            on: result("hello world", wallMs: 500, tokensOut: 5)
        )
        #expect(outcomes.map(\.pass) == [true, false, false, true])
        #expect(outcomes[1].reason == "not found")
        #expect(outcomes[2].reason == "500 > 100")
        #expect(outcomes[0].reason == nil)
    }

    @Test func evaluateAllEmpty() {
        #expect(Checks.evaluateAll(textCase([]), on: result("x")).isEmpty)
    }
}
