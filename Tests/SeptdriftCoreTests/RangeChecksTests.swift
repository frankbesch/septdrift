// SPEC §4 rules 8–10 (v0.3.5) — label sets, numeric bounds and ladder rungs.
import Foundation
import Testing
@testable import SeptdriftCore

private let fields = [
    SchemaField(name: "intent", kind: .string),
    SchemaField(name: "count", kind: .int),
    SchemaField(name: "score", kind: .double),
    SchemaField(name: "approved", kind: .bool),
    SchemaField(name: "materiality", kind: .string),
]

private let ladder = ["none", "low", "medium", "high"]

private func outcome(_ check: Check, _ content: String, error: ErrorKind? = nil) -> Outcome {
    let aCase = Case(id: "json-case", prompt: "p", format: .json, schema: fields, checks: [check])
    return Checks.evaluate(check, in: aCase, on: Result(content: content, wallMs: 1, error: error))
}

private struct Row: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let check: Check
    let content: String
    /// nil when the check passes.
    let reason: String?
}

private let rows: [Row] = [
    Row(testDescription: "in: a listed label passes",
        check: .jsonFieldIn(field: "intent", values: ["billing", "renewal"]),
        content: #"{"intent":"renewal"}"#, reason: nil),
    Row(testDescription: "in: an unlisted label fails",
        check: .jsonFieldIn(field: "intent", values: ["billing", "renewal"]),
        content: #"{"intent":"other"}"#, reason: "expected one of billing, renewal got other"),
    Row(testDescription: "in: typed by the schema kind, so the string 3 is not the int 3",
        check: .jsonFieldIn(field: "count", values: ["3", "4"]),
        content: #"{"count":"3"}"#, reason: "expected one of 3, 4 got 3"),
    Row(testDescription: "in: an int member passes",
        check: .jsonFieldIn(field: "count", values: ["3", "4"]),
        content: #"{"count":4}"#, reason: nil),
    Row(testDescription: "in: a missing field fails",
        check: .jsonFieldIn(field: "intent", values: ["billing"]),
        content: #"{"count":4}"#, reason: "missing"),
    Row(testDescription: "range: both bounds are inclusive (min)",
        check: .jsonFieldRange(field: "score", min: 0.5, max: 0.9),
        content: #"{"score":0.5}"#, reason: nil),
    Row(testDescription: "range: both bounds are inclusive (max)",
        check: .jsonFieldRange(field: "score", min: 0.5, max: 0.9),
        content: #"{"score":0.9}"#, reason: nil),
    Row(testDescription: "range: below min fails",
        check: .jsonFieldRange(field: "score", min: 0.5, max: nil),
        content: #"{"score":0.25}"#, reason: "0.25 < 0.5"),
    Row(testDescription: "range: above max fails, integral bound without a decimal point",
        check: .jsonFieldRange(field: "count", min: nil, max: 5),
        content: #"{"count":6}"#, reason: "6 > 5"),
    Row(testDescription: "range: a fractional value on an int field fails",
        check: .jsonFieldRange(field: "count", min: 1, max: 5),
        content: #"{"count":2.5}"#, reason: "not an integer: 2.5"),
    Row(testDescription: "range: a string is not a number",
        check: .jsonFieldRange(field: "score", min: 0, max: 1),
        content: #"{"score":"0.7"}"#, reason: "not a number: 0.7"),
    Row(testDescription: "range: a boolean is not a number",
        check: .jsonFieldRange(field: "score", min: 0, max: 1),
        content: #"{"score":true}"#, reason: "not a number: true"),
    Row(testDescription: "range: content that is not an object fails",
        check: .jsonFieldRange(field: "score", min: 0, max: 1),
        content: "0.7", reason: "not json object"),
    Row(testDescription: "rank: the floor rung passes",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: "medium", max: nil),
        content: #"{"materiality":"medium"}"#, reason: nil),
    Row(testDescription: "rank: a higher rung passes",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: "medium", max: nil),
        content: #"{"materiality":"high"}"#, reason: nil),
    Row(testDescription: "rank: a lower rung fails",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: "medium", max: nil),
        content: #"{"materiality":"low"}"#, reason: "low < medium"),
    Row(testDescription: "rank: above the ceiling fails",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: nil, max: "low"),
        content: #"{"materiality":"high"}"#, reason: "high > low"),
    Row(testDescription: "rank: a fail-closed value is off the ladder and never passes",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: "none", max: nil),
        content: #"{"materiality":"needs_review"}"#, reason: "off ladder: needs_review"),
    Row(testDescription: "rank: rungs are case-sensitive",
        check: .jsonFieldRank(field: "materiality", ladder: ladder, min: "none", max: nil),
        content: #"{"materiality":"High"}"#, reason: "off ladder: High"),
]

@Suite("Range checks")
struct RangeChecksTests {

    @Test("evaluation", arguments: rows)
    fileprivate func evaluation(_ row: Row) {
        #expect(outcome(row.check, row.content) == Outcome(pass: row.reason == nil, reason: row.reason))
    }

    @Test("a result carrying an error fails every new check with reason error")
    func errorFailsFirst() {
        let checks: [Check] = [
            .jsonFieldIn(field: "intent", values: ["billing"]),
            .jsonFieldRange(field: "score", min: 0, max: 1),
            .jsonFieldRank(field: "materiality", ladder: ladder, min: "low", max: nil),
        ]
        for check in checks {
            #expect(outcome(check, "", error: .refusal) == Outcome(pass: false, reason: "error"))
        }
    }

    @Test("name and arg render unambiguously as canonical JSON after the field")
    func identity() {
        let setCheck = Check.jsonFieldIn(field: "intent", values: ["a,b", "c"])
        #expect(setCheck.name == "json_field_in")
        #expect(setCheck.arg == #"intent=["a,b","c"]"#)
        #expect(Check.jsonFieldIn(field: "intent", values: ["a", "b,c"]).arg != setCheck.arg)

        let range = Check.jsonFieldRange(field: "score", min: 0.5, max: nil)
        #expect(range.name == "json_field_range")
        #expect(range.arg == "score=[0.5,null]")
        #expect(Check.jsonFieldRange(field: "count", min: 1, max: 5).arg == "count=[1,5]")

        let rank = Check.jsonFieldRank(field: "materiality", ladder: ladder, min: "medium", max: nil)
        #expect(rank.name == "json_field_rank")
        #expect(rank.arg == #"materiality={"ladder":["none","low","medium","high"],"max":null,"min":"medium"}"#)
    }
}

// MARK: - Loading (SPEC §1)

private func load(_ checks: String, format: String = "json") throws -> [Check] {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("septdrift-range-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let schema = format == "json" ? """
      schema:
        - {name: intent, kind: string}
        - {name: count, kind: int}
        - {name: score, kind: double}
        - {name: approved, kind: bool}

    """ : ""
    let yaml = """
    - id: range-case
      prompt: "p"
      format: \(format)
    \(schema)  checks:
        - \(checks)

    """
    let file = dir.appendingPathComponent("c.yaml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)
    return try CaseLoader.load(path: file.path)[0].checks
}

private struct Rejected: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let check: String
    var format = "json"
    /// A fragment of the validation message.
    let message: String
}

private let rejected: [Rejected] = [
    Rejected(testDescription: "in on a text case",
             check: "json_field_in: {field: intent, values: [a]}", format: "text", message: "needs format: json"),
    Rejected(testDescription: "in on an undeclared field",
             check: "json_field_in: {field: nope, values: [a]}", message: "nope"),
    Rejected(testDescription: "in with no values",
             check: "json_field_in: {field: intent, values: []}", message: "non-empty values list"),
    Rejected(testDescription: "in with a repeated value",
             check: "json_field_in: {field: intent, values: [a, a]}", message: "repeats a value"),
    Rejected(testDescription: "in with a value that does not fit the kind",
             check: "json_field_in: {field: count, values: [1, two]}", message: "does not fit the int field"),
    Rejected(testDescription: "in with an unknown key",
             check: "json_field_in: {field: intent, value: a}", message: "unknown key 'value'"),
    Rejected(testDescription: "range on a string field",
             check: "json_field_range: {field: intent, min: 1}", message: "needs an int or double field"),
    Rejected(testDescription: "range with no bound",
             check: "json_field_range: {field: score}", message: "needs min, max, or both"),
    Rejected(testDescription: "range with min above max",
             check: "json_field_range: {field: score, min: 2, max: 1}", message: "min above max"),
    Rejected(testDescription: "range with a fractional bound on an int field",
             check: "json_field_range: {field: count, min: 1.5}", message: "must be an integer"),
    Rejected(testDescription: "range with a non-numeric bound",
             check: "json_field_range: {field: score, min: low}", message: "min must be a number"),
    Rejected(testDescription: "rank on an int field",
             check: "json_field_rank: {field: count, ladder: [a, b], min: a}", message: "needs a string field"),
    Rejected(testDescription: "rank with a one-rung ladder",
             check: "json_field_rank: {field: intent, ladder: [a], min: a}", message: "at least two"),
    Rejected(testDescription: "rank with a repeated rung",
             check: "json_field_rank: {field: intent, ladder: [a, b, a], min: a}", message: "repeats a rung"),
    Rejected(testDescription: "rank with a bound off the ladder",
             check: "json_field_rank: {field: intent, ladder: [a, b], min: c}", message: "min must be a rung"),
    Rejected(testDescription: "rank with no bound",
             check: "json_field_rank: {field: intent, ladder: [a, b]}", message: "needs min, max, or both"),
    Rejected(testDescription: "rank with min above max",
             check: "json_field_rank: {field: intent, ladder: [a, b], min: b, max: a}", message: "min above max"),
]

@Suite("Range checks loading")
struct RangeChecksLoadingTests {

    @Test("the three checks load from YAML")
    func loads() throws {
        #expect(try load("json_field_in: {field: count, values: [3, 4]}")
            == [.jsonFieldIn(field: "count", values: ["3", "4"])])
        #expect(try load("json_field_range: {field: score, min: 0.5}")
            == [.jsonFieldRange(field: "score", min: 0.5, max: nil)])
        #expect(try load("json_field_rank: {field: intent, ladder: [none, low, high], min: low, max: high}")
            == [.jsonFieldRank(field: "intent", ladder: ["none", "low", "high"], min: "low", max: "high")])
    }

    @Test("validation rejects", arguments: rejected)
    fileprivate func rejects(_ row: Rejected) {
        do {
            _ = try load(row.check, format: row.format)
            Issue.record("loaded: \(row.check)")
        } catch {
            let text = String(describing: error)
            #expect(text.contains(row.message), "\(text)")
        }
    }
}
