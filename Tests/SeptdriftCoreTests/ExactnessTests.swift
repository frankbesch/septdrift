// Codex review 0602, the week-2 leftovers: exact integers (#4, #14), an unfinished trailer
// (#5), and one byte snapshot for verify and read (#8).
import Foundation
import Testing
@testable import SeptdriftCore

private func recording() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("septdrift-exact-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("run.jsonl")
    let aCase = Case(id: "only", prompt: "p", checks: [.contains("ok")])
    let recorder = try Recorder(url: url, force: false)
    try recorder.writeHeader(
        runID: "run-1", ts: "t0",
        host: HostInfo(os: "macOS 27.0", osBuild: "27A100", chip: "Apple M1", name: ""),
        backend: "fixture", casesSHA256: Recorder.casesSHA256([aCase]),
        expected: [ExpectedEntry(caseID: aCase.id, repeatCount: 1)])
    let result = Result(content: "ok", wallMs: 9_007_199_254_740_993, assetIDs: [])
    try recorder.writeResult(
        runID: "run-1", ts: "t1", caseID: aCase.id, rep: 0,
        requestSHA256: Recorder.requestSHA256(for: aCase), result: result,
        checks: zip(aCase.checks, Checks.evaluateAll(aCase, on: result)).map(CheckRecord.init))
    try recorder.writeEnd(runID: "run-1", ts: "t2")
    return url
}

@Suite("Exact numbers")
struct ExactNumberTests {

    @Test("an integer above 2^53 parses exactly and round-trips")
    func largeIntegerRoundTrips() throws {
        let line = Data(#"{"n":9007199254740993}"#.utf8)
        #expect(try Canonical.parse(line)["n"] == .int(9_007_199_254_740_993))
        #expect(Canonical.isCanonical(line))
        #expect(Canonical.isCanonical(Data(#"{"n":-9223372036854775808}"#.utf8)))
    }

    @Test("an integer beyond Int64 is not canonical")
    func overflowingIntegerIsRejected() {
        #expect(!Canonical.isCanonical(Data(#"{"n":18446744073709551615}"#.utf8)))
        #expect(!Canonical.isCanonical(Data(#"{"n":123456789012345678901234567890}"#.utf8)))
    }

    @Test("a large double keeps one stable rendering")
    func largeDoubleIsStable() throws {
        let text = Canonical.string(of: .obj([("n", .double(1e16))]))
        #expect(Canonical.isCanonical(Data(text.utf8)))
        #expect(try Canonical.parse(Data(text.utf8))["n"] == .double(1e16))
    }

    @Test("a recording with a wallMs above 2^53 verifies and reads back exactly")
    func largeWallMsVerifies() throws {
        let url = try recording()
        #expect(Recorder.verify(url: url) == VerifyResult(ok: true, count: 1))
        #expect(try Recorder.read(url: url).results[0].result.wallMs == 9_007_199_254_740_993)
    }

    @Test("a non-finite temperature is a validation error")
    func nonFiniteTemperatureIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("septdrift-exact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("c.yaml")
        try """
        - id: hot
          prompt: "p"
          options:
            temperature: .inf
          checks:
            - contains: "x"

        """.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: CaseError.self) { _ = try CaseLoader.load(path: file.path) }
    }

    private func intOutcome(_ content: String, _ check: Check) -> Outcome {
        let aCase = Case(
            id: "json-case", prompt: "p", format: .json,
            schema: [SchemaField(name: "count", kind: .int)], checks: [check])
        return Checks.evaluate(check, in: aCase, on: Result(content: content, wallMs: 1))
    }

    @Test("int equality is exact above 2^53")
    func intEqualityIsExact() {
        let exact = Check.jsonFieldEquals(field: "count", value: "9007199254740993")
        #expect(intOutcome(#"{"count":9007199254740993}"#, exact).pass)
        #expect(!intOutcome(#"{"count":9007199254740992}"#, exact).pass)
        // A fractional literal that a Double rounds to an integer is not an integer.
        let rounded = Check.jsonFieldEquals(field: "count", value: "9007199254740992")
        #expect(!intOutcome(#"{"count":9007199254740992.5}"#, rounded).pass)
        #expect(intOutcome(#"{"count":3.0}"#, .jsonFieldEquals(field: "count", value: "3")).pass)
        #expect(!intOutcome(#"{"count":3.5}"#, .jsonFieldEquals(field: "count", value: "3")).pass)
    }

    @Test("an int range rejects a fractional literal that rounds to an integer")
    func intRangeIsExact() {
        let range = Check.jsonFieldRange(field: "count", min: 0, max: nil)
        #expect(intOutcome(#"{"count":9007199254740993}"#, range).pass)
        #expect(intOutcome(#"{"count":9007199254740992.5}"#, range).reason?.hasPrefix("not an integer") == true)
    }
}

@Suite("Unfinished trailer and one snapshot")
struct SnapshotTests {

    @Test("a trailer cut short before its newline is incomplete")
    func truncatedTrailerIsIncomplete() throws {
        let url = try recording()
        let data = try Data(contentsOf: url)
        #expect(Recorder.verify(data: data.dropLast(20)) == VerifyResult(ok: false, count: 0, failure: "incomplete"))
    }

    @Test("a malformed final record that ends with a newline is non-canonical")
    func finishedGarbageIsNonCanonical() throws {
        let url = try recording()
        var data = try Data(contentsOf: url)
        data.append(Data("{not json\n".utf8))
        #expect(Recorder.verify(data: data).failure == "non-canonical at seq 3")
    }

    @Test("a complete trailer without a final newline still verifies")
    func missingFinalNewlineVerifies() throws {
        let url = try recording()
        let data = try Data(contentsOf: url)
        #expect(data.last == 0x0A)
        #expect(Recorder.verify(data: data.dropLast(1)).ok)
    }

    @Test("verify and read agree on bytes in memory and on the file")
    func dataAndURLAgree() throws {
        let url = try recording()
        let data = try Data(contentsOf: url)
        #expect(Recorder.verify(data: data) == Recorder.verify(url: url))
        #expect(try Recorder.read(data: data).results == Recorder.read(url: url).results)
    }

    @Test("a side that cannot be read is unreadable, not unverified")
    func missingSideIsUnreadable() throws {
        let url = try recording()
        let missing = url.deletingLastPathComponent().appendingPathComponent("nope.jsonl")
        do {
            _ = try Diff.diff(a: url, b: missing, options: DiffOptions())
            Issue.record("diff of a missing file succeeded")
        } catch let error as DiffError {
            guard case .unreadable(let side, _) = error else {
                Issue.record("got \(error)"); return
            }
            #expect(side == "B")
        }
    }
}
