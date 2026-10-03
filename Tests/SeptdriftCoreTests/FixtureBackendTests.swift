// SPEC §2/§7 — the fixture backend: deterministic lookup by (caseID, rep), typed errors,
// duplicate keys rejected. Zero live calls.
import Foundation
import Testing
@testable import SeptdriftCore

/// The repo's real fixture file, located relative to this source file.
private var sideAURL: URL {
    URL(fileURLWithPath: #filePath)          // Tests/SeptdriftCoreTests/FixtureBackendTests.swift
        .deletingLastPathComponent()          // Tests/SeptdriftCoreTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent("fixtures/side-a.jsonl")
}

/// Write an inline JSONL fixture into a temp directory; nothing lands in the repo.
private func tempFixture(_ contents: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fmspike-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("fixture.jsonl")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
}

private func textCase(_ id: String) -> Case {
    Case(id: id, prompt: "p", checks: [.contains("x")])
}

@Test("the repo fixture file loads and replays afe-no-context rep 0")
func fixtureReplaysRecordedResult() async throws {
    let backend = try FixtureBackend(fileURL: sideAURL)
    #expect(backend.name == "fixture")

    let result = try await backend.respond(to: textCase("afe-no-context"), rep: 0)
    #expect(result.content ==
        "An AFE is an Authorization for Expenditure that requests approval of estimated well costs.")
    #expect(result.wallMs == 700)
    #expect(result.tokensIn == 42)
    #expect(result.tokensCached == 0)
    #expect(result.tokensOut == 20)
    #expect(result.tokensReasoning == 0)
    #expect(result.assetIDs == ["fixture-model-1"])
    #expect(result.error == nil)
}

@Test("per-rep records are distinct")
func fixtureKeysByRep() async throws {
    let backend = try FixtureBackend(fileURL: sideAURL)
    let rep0 = try await backend.respond(to: textCase("repeat-ready"), rep: 0)
    let rep2 = try await backend.respond(to: textCase("repeat-ready"), rep: 2)
    #expect(rep0.wallMs == 600)
    #expect(rep2.wallMs == 1000)
}

@Test("an unknown (caseID, rep) becomes error other / 'no fixture'")
func fixtureMissingKey() async throws {
    let backend = try FixtureBackend(fileURL: sideAURL)

    let unknownCase = try await backend.respond(to: textCase("not-recorded"), rep: 0)
    #expect(unknownCase.error == .other)
    #expect(unknownCase.errorDetail == "no fixture")
    #expect(unknownCase.content == "")
    #expect(unknownCase.wallMs == 0)

    let unknownRep = try await backend.respond(to: textCase("afe-no-context"), rep: 7)
    #expect(unknownRep.error == .other)
    #expect(unknownRep.errorDetail == "no fixture")
}

@Test("error: guardrail maps to ErrorKind.guardrail with empty content")
func fixtureTypedError() async throws {
    let backend = try FixtureBackend(fileURL: sideAURL)
    let result = try await backend.respond(to: textCase("guardrail-error"), rep: 0)
    #expect(result.error == .guardrail)
    #expect(result.content == "")
    #expect(result.wallMs == 500)
}

@Test("a duplicate (caseID, rep) is rejected")
func fixtureDuplicateKey() throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"content":"one","wallMs":1}
        {"caseID":"b","rep":0,"content":"two","wallMs":2}
        {"caseID":"a","rep":0,"content":"again","wallMs":3}
        """)
    #expect(throws: FixtureError.duplicateKey(caseID: "a", rep: 0, line: 3)) {
        _ = try FixtureBackend(fileURL: file)
    }
}

@Test("an unknown error string is rejected")
func fixtureInvalidErrorKind() throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"content":"","wallMs":1,"error":"meltdown"}
        """)
    #expect(throws: FixtureError.self) {
        _ = try FixtureBackend(fileURL: file)
    }
    do {
        _ = try FixtureBackend(fileURL: file)
        Issue.record("expected a FixtureError")
    } catch let error as FixtureError {
        guard case .invalidErrorKind(_, let line, let value) = error else {
            Issue.record("expected invalidErrorKind, got \(error)")
            return
        }
        #expect(line == 1)
        #expect(value == "meltdown")
    }
}

@Test("a line with no content and no error is rejected")
func fixtureRejectsMissingContent() throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"wallMs":1}
        """)
    #expect(throws: FixtureError.missingField(file: file.path, line: 1, field: "content")) {
        _ = try FixtureBackend(fileURL: file)
    }
}

@Test("a line with no wallMs is rejected")
func fixtureRejectsMissingWallMs() throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"content":"one"}
        """)
    #expect(throws: FixtureError.missingField(file: file.path, line: 1, field: "wallMs")) {
        _ = try FixtureBackend(fileURL: file)
    }
}

@Test("negative usage values are rejected")
func fixtureRejectsNegativeUsage() throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"content":"one","wallMs":1,"tokensIn":-5}
        """)
    #expect(throws: FixtureError.negativeValue(file: file.path, line: 1, field: "tokensIn")) {
        _ = try FixtureBackend(fileURL: file)
    }
}

@Test("an error line needs no content")
func errorLineNeedsNoContent() async throws {
    let file = try tempFixture("""
        {"caseID":"a","rep":0,"wallMs":1,"error":"guardrail"}
        """)
    let backend = try FixtureBackend(fileURL: file)
    let result = try await backend.respond(to: textCase("a"), rep: 0)
    #expect(result.error == .guardrail)
    #expect(result.content == "")
}

@Test("lookup is deterministic across loads")
func fixtureDeterministic() async throws {
    let first = try FixtureBackend(fileURL: sideAURL)
    let second = try FixtureBackend(fileURL: sideAURL)
    let a = try await first.respond(to: textCase("ordered-json"), rep: 0)
    let b = try await second.respond(to: textCase("ordered-json"), rep: 0)
    #expect(a == b)
    #expect(a.content == #"{"kind":"request","count":3,"approved":true}"#)
}
