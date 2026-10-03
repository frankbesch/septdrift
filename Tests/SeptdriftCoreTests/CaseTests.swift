// SPEC §7 — case parsing: valid, each validation error, directory ordering, ordered schema, options.
import Foundation
import Testing
@testable import SeptdriftCore

/// A temp directory that holds inline fixtures. Nothing is written into the repo.
private struct TempDir {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmspike-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    @discardableResult
    func write(_ name: String, _ contents: String) throws -> String {
        let path = url.appendingPathComponent(name)
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }
    var path: String { url.path }
}

/// Load one inline YAML fixture and return the error it raises, or nil.
private func loadError(_ yaml: String, ext: String = "yaml") throws -> CaseError? {
    let dir = try TempDir()
    let file = try dir.write("case.\(ext)", yaml)
    do {
        _ = try CaseLoader.load(path: file)
        return nil
    } catch let error as CaseError {
        return error
    }
}

@Suite("Case loading")
struct CaseLoadingTests {

    @Test("valid YAML loads with every field")
    func validYAML() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: text-case
          instructions: "Answer in one sentence."
          context: "AFE = Authorization for Expenditure."
          prompt: "What is an AFE?"
          repeat: 3
          checks:
            - contains: "AFE"
            - not_contains: "sorry"
            - regex: "A[A-Z]+"
            - max_wall_ms: 3000
            - max_output_tokens: 80
        - id: json-case
          prompt: "Classify the document."
          format: json
          schema:
            - {name: kind, kind: string, description: "document type", optional: false}
            - {name: amount, kind: double}
          options:
            temperature: 0.0
            max_response_tokens: 200
          checks:
            - json_field_equals: {field: kind, value: "AFE"}
        """)
        let cases = try CaseLoader.load(path: file)
        #expect(cases.count == 2)
        #expect(cases[0].id == "text-case")
        #expect(cases[0].instructions == "Answer in one sentence.")
        #expect(cases[0].context == "AFE = Authorization for Expenditure.")
        #expect(cases[0].format == .text)
        #expect(cases[0].schema == nil)
        #expect(cases[0].options == nil)
        #expect(cases[0].repeat == 3)
        #expect(cases[0].checks == [
            .contains("AFE"), .notContains("sorry"), .regex("A[A-Z]+"),
            .maxWallMs(3000), .maxOutputTokens(80)
        ])
        #expect(cases[1].format == .json)
        #expect(cases[1].schema == [
            SchemaField(name: "kind", kind: .string, description: "document type", optional: false),
            SchemaField(name: "amount", kind: .double)
        ])
        #expect(cases[1].options == GenerationOptionsSpec(temperature: 0.0, maxResponseTokens: 200))
        #expect(cases[1].repeat == 1)
        #expect(cases[1].checks == [.jsonFieldEquals(field: "kind", value: "AFE")])
    }

    @Test("schema keeps file order and optional defaults to false")
    func schemaIsOrdered() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: ordered-case
          prompt: "p"
          format: json
          schema:
            - {name: zulu, kind: string}
            - {name: alpha, kind: int, optional: true}
            - {name: mike, kind: bool}
          checks:
            - json_field_equals: {field: alpha, value: "1"}
        """)
        let schema = try #require(try CaseLoader.load(path: file).first?.schema)
        #expect(schema.map(\.name) == ["zulu", "alpha", "mike"])
        #expect(schema.map(\.kind) == [.string, .int, .bool])
        #expect(schema.map(\.optional) == [false, true, false])
        #expect(schema[0].description == nil)
    }

    @Test("options accept either key alone")
    func partialOptions() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: temp-only
          prompt: "p"
          options:
            temperature: 0.7
          checks: [{contains: "x"}]
        - id: tokens-only
          prompt: "p"
          options:
            max_response_tokens: 64
          checks: [{contains: "x"}]
        """)
        let cases = try CaseLoader.load(path: file)
        #expect(cases[0].options == GenerationOptionsSpec(temperature: 0.7, maxResponseTokens: nil))
        #expect(cases[1].options == GenerationOptionsSpec(temperature: nil, maxResponseTokens: 64))
    }

    @Test("expect_error parses each declared kind and any")
    func expectErrorParsing() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: e-guardrail
          prompt: "p"
          checks: [{expect_error: guardrail}]
        - id: e-refusal
          prompt: "p"
          checks: [{expect_error: refusal}]
        - id: e-unsupported
          prompt: "p"
          checks: [{expect_error: unsupported}]
        - id: e-context
          prompt: "p"
          checks: [{expect_error: context}]
        - id: e-unavailable
          prompt: "p"
          checks: [{expect_error: unavailable}]
        - id: e-any
          prompt: "p"
          checks: [{expect_error: any}]
        """)
        let cases = try CaseLoader.load(path: file)
        #expect(cases.map(\.checks) == [
            [.expectError(.guardrail)], [.expectError(.refusal)], [.expectError(.unsupported)],
            [.expectError(.context)], [.expectError(.unavailable)], [.expectError(nil)]
        ])
    }

    @Test("json_field_equals accepts bare scalars and stringifies them")
    func jsonFieldEqualsScalarValues() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: scalar-case
          prompt: "p"
          format: json
          schema:
            - {name: kind, kind: string}
            - {name: count, kind: int}
            - {name: amount, kind: double}
            - {name: approved, kind: bool}
          checks:
            - json_field_equals: {field: kind, value: "request"}
            - json_field_equals: {field: count, value: 3}
            - json_field_equals: {field: amount, value: 1.5}
            - json_field_equals: {field: approved, value: true}
        """)
        let cases = try CaseLoader.load(path: file)
        #expect(cases[0].checks == [
            .jsonFieldEquals(field: "kind", value: "request"),
            .jsonFieldEquals(field: "count", value: "3"),
            .jsonFieldEquals(field: "amount", value: "1.5"),
            .jsonFieldEquals(field: "approved", value: "true")
        ])
    }

    @Test("json_field_equals value 1 stays numeric, not boolean true")
    func jsonZeroAndOneStayNumeric() throws {
        let dir = try TempDir()
        let file = try dir.write("c.yaml", """
        - id: numeric-case
          prompt: "p"
          format: json
          schema:
            - {name: count, kind: int}
          checks:
            - json_field_equals: {field: count, value: 1}
        """)
        let cases = try CaseLoader.load(path: file)
        // A bare 1 is an int, not a boolean: it must render "1", not "true".
        #expect(cases[0].checks == [.jsonFieldEquals(field: "count", value: "1")])

        // A schema `optional: 1` (numeric, not a real boolean) is rejected by `bool(_:)`,
        // which now only accepts a CFBoolean-backed NSNumber or a native Swift Bool.
        let error = try loadError("""
        - id: numeric-optional
          prompt: "p"
          format: json
          schema:
            - {name: count, kind: int, optional: 1}
          checks:
            - contains: "x"
        """)
        guard case .invalidValue(_, _, let field) = error else {
            Issue.record("got \(String(describing: error))"); return
        }
        #expect(field == "schema.optional")
    }

    @Test("schema field name must be an identifier")
    func schemaFieldNameMustBeIdentifier() throws {
        let error = try loadError("""
        - id: bad-field-name
          prompt: "p"
          format: json
          schema:
            - {name: "a=b", kind: string}
          checks:
            - contains: "x"
        """)
        guard case .invalidSchemaFieldName(_, let id, let field) = error else {
            Issue.record("got \(String(describing: error))"); return
        }
        #expect(id == "bad-field-name")
        #expect(field == "a=b")
    }

    @Test("valid JSON loads")
    func validJSON() throws {
        let dir = try TempDir()
        let file = try dir.write("c.json", """
        [
          {"id": "json-file-case", "prompt": "hello",
           "checks": [{"contains": "hi"}, {"max_wall_ms": 500}]},
          {"id": "second-case", "prompt": "again", "format": "json",
           "schema": [{"name": "kind", "kind": "string"}], "repeat": 2,
           "checks": [{"json_field_equals": {"field": "kind", "value": "AFE"}}]}
        ]
        """)
        let cases = try CaseLoader.load(path: file)
        #expect(cases.map(\.id) == ["json-file-case", "second-case"])
        #expect(cases[0].checks == [.contains("hi"), .maxWallMs(500)])
        #expect(cases[1].repeat == 2)
        #expect(cases[1].schema == [SchemaField(name: "kind", kind: .string)])
    }

    @Test("check name and arg render for the receipt")
    func checkNameAndArg() {
        #expect(Check.contains("a").name == "contains")
        #expect(Check.notContains("a").name == "not_contains")
        #expect(Check.regex("a").name == "regex")
        #expect(Check.jsonFieldEquals(field: "k", value: "v").name == "json_field_equals")
        #expect(Check.maxWallMs(10).name == "max_wall_ms")
        #expect(Check.maxOutputTokens(10).name == "max_output_tokens")
        #expect(Check.expectError(.guardrail).name == "expect_error")
        #expect(Check.contains("needle").arg == "needle")
        #expect(Check.jsonFieldEquals(field: "k", value: "v").arg == "k=v")
        #expect(Check.maxWallMs(3000).arg == "3000")
        #expect(Check.maxOutputTokens(80).arg == "80")
        #expect(Check.expectError(.guardrail).arg == "guardrail")
        #expect(Check.expectError(nil).arg == "any")
    }

    @Test("check identity (name, arg) is hashable and distinct")
    func checkIsHashable() {
        let set: Set<Check> = [
            .contains("a"), .contains("a"), .contains("b"),
            .expectError(nil), .expectError(.guardrail)
        ]
        #expect(set.count == 4)
    }
}

@Suite("Case validation errors")
struct CaseValidationTests {

    @Test("missing id")
    func missingID() throws {
        let error = try loadError("""
        - prompt: "hello"
          checks:
            - contains: "hi"
        """)
        guard case .missingID(_, let index) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(index == 0)
        #expect(error!.description.contains("has no id"))
    }

    @Test("missing prompt")
    func missingPrompt() throws {
        let error = try loadError("""
        - id: a-case
          checks:
            - contains: "hi"
        """)
        guard case .missingPrompt(let file, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(error!.description.contains(file))
        #expect(error!.description.contains("a-case"))
    }

    @Test("missing checks")
    func missingChecks() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
        """)
        guard case .missingChecks(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
    }

    @Test("empty checks")
    func emptyChecks() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks: []
        """)
        guard case .emptyChecks(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(error!.description.contains("at least one check"))
    }

    @Test("duplicate id across the whole load")
    func duplicateID() throws {
        let dir = try TempDir()
        try dir.write("a.yaml", """
        - id: same-id
          prompt: "one"
          checks:
            - contains: "x"
        """)
        try dir.write("b.yaml", """
        - id: same-id
          prompt: "two"
          checks:
            - contains: "x"
        """)
        var caught: CaseError?
        do { _ = try CaseLoader.load(path: dir.path) } catch let e as CaseError { caught = e }
        guard case .duplicateID(_, let id, let firstFile) = caught else {
            Issue.record("got \(String(describing: caught))"); return
        }
        #expect(id == "same-id")
        #expect(firstFile.hasSuffix("a.yaml"))
    }

    @Test("id not matching [a-z0-9-]+")
    func invalidID() throws {
        let error = try loadError("""
        - id: Bad_ID
          prompt: "hello"
          checks:
            - contains: "x"
        """)
        guard case .invalidID(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "Bad_ID")
        #expect(error!.description.contains("[a-z0-9-]+"))
    }

    @Test("schema without format json")
    func schemaWithoutJSON() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          schema:
            - {name: kind, kind: string}
          checks:
            - contains: "x"
        """)
        guard case .schemaWithoutJSONFormat(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
    }

    @Test("format json without schema")
    func jsonWithoutSchema() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          format: json
          checks:
            - contains: "x"
        """)
        guard case .jsonFormatWithoutSchema(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
    }

    @Test("schema as a mapping is not a list")
    func schemaMustBeAList() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          format: json
          schema:
            kind: string
          checks:
            - contains: "x"
        """)
        guard case .invalidValue(_, let id, let field) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(field == "schema")
    }

    @Test("duplicate schema field names")
    func duplicateSchemaField() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          format: json
          schema:
            - {name: kind, kind: string}
            - {name: kind, kind: int}
          checks:
            - json_field_equals: {field: kind, value: "AFE"}
        """)
        guard case .duplicateSchemaField(_, let id, let field) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(field == "kind")
        #expect(error!.description.contains("twice"))
    }

    @Test("unknown schema field kind")
    func invalidFieldKind() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          format: json
          schema:
            - {name: kind, kind: money}
          checks:
            - json_field_equals: {field: kind, value: "AFE"}
        """)
        guard case .invalidFieldKind(_, _, let field, let value) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(field == "kind")
        #expect(value == "money")
    }

    @Test("invalid options value")
    func invalidOptions() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          options:
            temperature: "warm"
          checks:
            - contains: "x"
        """)
        guard case .invalidValue(_, let id, let field) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(field == "options.temperature")
    }

    @Test("repeat below range")
    func repeatTooSmall() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          repeat: 0
          checks:
            - contains: "x"
        """)
        guard case .repeatOutOfRange(_, let id, let value) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(value == "0")
    }

    @Test("repeat above range")
    func repeatTooLarge() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          repeat: 21
          checks:
            - contains: "x"
        """)
        guard case .repeatOutOfRange(_, _, let value) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(value == "21")
        #expect(error!.description.contains("1...20"))
    }

    @Test("unknown check key")
    func unknownCheck() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks:
            - sounds_nice: "x"
        """)
        guard case .unknownCheck(_, let id, let key) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(key == "sounds_nice")
    }

    @Test("invalid regex pattern")
    func invalidRegex() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks:
            - regex: "([unclosed"
        """)
        guard case .invalidRegex(_, let id, let pattern, _) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(pattern == "([unclosed")
    }

    @Test("json_field_equals with format text")
    func jsonFieldEqualsWithText() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks:
            - json_field_equals: {field: kind, value: "AFE"}
        """)
        guard case .jsonFieldEqualsWithTextFormat(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(error!.description.contains("format json"))
    }

    @Test("json_field_equals on a field the schema does not declare")
    func jsonFieldEqualsUnknownField() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          format: json
          schema:
            - {name: kind, kind: string}
          checks:
            - json_field_equals: {field: amount, value: "10"}
        """)
        guard case .unknownSchemaField(_, let id, let field) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(field == "amount")
    }

    @Test("expect_error with an unknown kind")
    func invalidErrorKind() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks:
            - expect_error: sulking
        """)
        guard case .invalidErrorKind(_, let id, let value) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(value == "sulking")
    }

    @Test("expect_error combined with another check")
    func expectErrorWithOtherChecks() throws {
        let error = try loadError("""
        - id: a-case
          prompt: "hello"
          checks:
            - expect_error: guardrail
            - contains: "x"
        """)
        guard case .expectErrorWithOtherChecks(_, let id) = error else { Issue.record("got \(String(describing: error))"); return }
        #expect(id == "a-case")
        #expect(error!.description.contains("only check"))
    }
}

/// A path inside the repo, relative to this test file.
private func repoFile(_ relative: String) -> String {
    URL(fileURLWithPath: #filePath)          // Tests/SeptdriftCoreTests/CaseTests.swift
        .deletingLastPathComponent()          // Tests/SeptdriftCoreTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent(relative).path
}

@Suite("Case loading from a path")
struct CasePathTests {

    @Test("directory loads in filename order, non-case files ignored")
    func directoryOrdering() throws {
        let dir = try TempDir()
        try dir.write("c-third.yaml", "- {id: third, prompt: p, checks: [{contains: x}]}\n")
        try dir.write("a-first.json", "[{\"id\": \"first\", \"prompt\": \"p\", \"checks\": [{\"contains\": \"x\"}]}]")
        try dir.write("b-second.yml", "- {id: second, prompt: p, checks: [{contains: x}]}\n")
        try dir.write("README.md", "not a case file")
        let cases = try CaseLoader.load(path: dir.path)
        #expect(cases.map(\.id) == ["first", "second", "third"])
    }

    @Test("missing path is unreadable")
    func missingPath() throws {
        var caught: CaseError?
        do { _ = try CaseLoader.load(path: "/nonexistent/septdrift/cases") }
        catch let e as CaseError { caught = e }
        guard case .unreadable = caught else { Issue.record("got \(String(describing: caught))"); return }
    }

    @Test("the repo's cases/day2.yaml loads with 6 cases")
    func repoDay2Cases() throws {
        let path = repoFile("cases/day2.yaml")
        let cases = try CaseLoader.load(path: path)
        #expect(cases.count == 6)
        #expect(cases.map(\.id) == [
            "afe-no-context", "afe-with-context", "ordered-json",
            "repeat-ready", "guardrail-error", "status-summary"
        ])
        #expect(cases[2].schema?.map(\.name) == ["kind", "count", "approved"])
        #expect(cases[2].checks == [
            .jsonFieldEquals(field: "kind", value: "request"),
            .jsonFieldEquals(field: "count", value: "3"),
            .jsonFieldEquals(field: "approved", value: "true")
        ])
        #expect(cases[3].repeat == 3)
        #expect(cases[4].checks == [.expectError(.guardrail)])
    }

    @Test("the repo's cases/day2.yaml loads with 6 cases (cases/afe.yaml was removed, superseded by day2.yaml)")
    func repoAFECases() throws {
        let path = repoFile("cases/day2.yaml")
        let cases = try CaseLoader.load(path: path)
        #expect(cases.count == 6)
    }

    @Test("the whole cases/ directory loads successfully")
    func repoCasesDirectoryLoads() throws {
        let path = repoFile("cases")
        let cases = try CaseLoader.load(path: path)
        #expect(cases.count == 24)  // day2.yaml (6) + guardrails.yaml (3) + semi-deterministic.yaml (6) + typed-questions.yaml (9)
    }
}
