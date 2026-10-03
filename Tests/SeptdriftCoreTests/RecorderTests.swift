// SPEC §3 and §7 — canonical bytes, the ten hash vectors, and the chain that `verify` checks.
import Foundation
import Testing
@testable import SeptdriftCore

// MARK: - Fixtures

private func scratchDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("septdrift-recorder-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let sampleHost = HostInfo(os: "macOS 27.0", osBuild: "27A100", chip: "Apple M1", name: "")

private func sampleCase(_ id: String) -> Case {
    Case(
        id: id,
        instructions: "Be terse.",
        prompt: "What is an AFE?",
        format: .text,
        repeat: 1,
        checks: [.contains("AFE")])
}

private func sampleResult(_ content: String) -> Result {
    Result(content: content, wallMs: 12, tokensIn: 7, tokensOut: 9, assetIDs: ["asset-1"])
}

/// Header + 3 results + trailer, in a fresh directory.
@discardableResult
private func writeRecording(at url: URL, contents: [String] = ["alpha", "bravo", "charlie"]) throws -> [String] {
    let recorder = try Recorder(url: url, force: false)
    let cases = contents.enumerated().map { sampleCase("case-\($0.offset)") }
    try recorder.writeHeader(
        runID: "run-1",
        ts: "2026-09-22T00:00:00Z",
        host: sampleHost,
        backend: "fixture",
        casesSHA256: Recorder.casesSHA256(cases),
        expected: cases.map { ExpectedEntry(caseID: $0.id, repeatCount: $0.repeat) })
    for (index, text) in contents.enumerated() {
        let aCase = cases[index]
        let result = sampleResult(text)
        try recorder.writeResult(
            runID: "run-1",
            ts: "2026-09-22T00:00:0\(index)Z",
            caseID: aCase.id,
            rep: 0,
            requestSHA256: Recorder.requestSHA256(for: aCase),
            result: result,
            checks: zip(aCase.checks, Checks.evaluateAll(aCase, on: result)).map(CheckRecord.init))
    }
    try recorder.writeEnd(runID: "run-1", ts: "2026-09-22T00:00:09Z")
    return contents
}

private func readLines(_ url: URL) throws -> [String] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func writeLines(_ lines: [String], to url: URL) throws {
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Canonical bytes

@Suite("Canonical bytes")
struct CanonicalTests {

    @Test("the ten fixed hash vectors match python3", arguments: HashVectors.all)
    func vector(_ vector: HashVector) {
        let bytes = Canonical.bytes(of: vector.value)
        #expect(String(decoding: bytes, as: UTF8.self) == vector.canonical, "\(vector.name) bytes")
        #expect(Canonical.sha256Hex(bytes) == vector.sha256, "\(vector.name) sha256")
        #expect(Canonical.sha256Hex(of: vector.value) == vector.sha256)
        // The canonical bytes must themselves be recognised as canonical.
        #expect(Canonical.isCanonical(bytes), "\(vector.name) round trip")
    }

    @Test("whitespace and key order make a line non-canonical")
    func nonCanonicalForms() {
        #expect(Canonical.isCanonical(Data(#"{"a":1,"b":2}"#.utf8)))
        #expect(!Canonical.isCanonical(Data(#"{"a": 1,"b":2}"#.utf8)))
        #expect(!Canonical.isCanonical(Data(#"{"b":2,"a":1}"#.utf8)))
        #expect(!Canonical.isCanonical(Data(#"{"d":2.0}"#.utf8)))
        #expect(!Canonical.isCanonical(Data("not json".utf8)))
    }

    @Test("solidus is not escaped and absent optionals are null")
    func slashAndNull() {
        #expect(Canonical.string(of: .string("a/b")) == #""a/b""#)
        #expect(Canonical.string(of: .stringOrNull(nil)) == "null")
        #expect(Canonical.string(of: .intOrNull(nil)) == "null")
    }

    @Test("keys sort by byte order, not by collation")
    func byteOrderSort() {
        let value = JSONValue.obj([("b", .int(1)), ("A", .int(2)), ("a", .int(3))])
        #expect(Canonical.string(of: value) == #"{"A":2,"a":3,"b":1}"#)
    }
}

// MARK: - Request and cases hashes

@Suite("Request hashing")
struct RequestHashTests {

    @Test("requestSHA256 ignores id, repeat and checks")
    func requestIgnoresNonRequestFields() {
        var a = sampleCase("one")
        var b = sampleCase("two")
        b.repeat = 5
        b.checks = [.maxWallMs(10)]
        #expect(Recorder.requestSHA256(for: a) == Recorder.requestSHA256(for: b))
        a.prompt = "different"
        #expect(Recorder.requestSHA256(for: a) != Recorder.requestSHA256(for: b))
    }

    @Test("casesSHA256 tracks id, repeat and checks")
    func casesTrackEverything() {
        let a = sampleCase("one")
        var b = sampleCase("one")
        #expect(Recorder.casesSHA256([a]) == Recorder.casesSHA256([b]))
        b.repeat = 2
        #expect(Recorder.casesSHA256([a]) != Recorder.casesSHA256([b]))
    }

    @Test("schema order is part of the request")
    func schemaOrderMatters() {
        let kind = SchemaField(name: "kind", kind: .string)
        let amount = SchemaField(name: "amount", kind: .double)
        var a = sampleCase("one")
        a.format = .json
        a.schema = [kind, amount]
        var b = a
        b.schema = [amount, kind]
        #expect(Recorder.requestSHA256(for: a) != Recorder.requestSHA256(for: b))
    }
}

// MARK: - Recording and verification

@Suite("Recorder chain")
struct RecorderChainTests {

    @Test("header + 3 results + trailer verifies")
    func happyPath() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        let result = Recorder.verify(url: url)
        #expect(result.ok, "\(result.failure ?? "")")
        #expect(result.count == 3)
        #expect(result.message == "OK 3 results")

        let lines = try readLines(url)
        #expect(lines.count == 5)
        // The chain links each record's `prev` to the previous record's `sha256` VALUE.
        let values = try lines.map { try Canonical.parse(Data($0.utf8)) }
        #expect(values[0]["prev"]?.stringValue == "")
        for index in 1..<values.count {
            #expect(values[index]["prev"]?.stringValue == values[index - 1]["sha256"]?.stringValue)
            #expect(values[index]["seq"]?.intValue == index)
        }
        #expect(values[4]["count"]?.intValue == 3)
    }

    @Test("read returns the header, the results and the trailer")
    func readBack() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        let (header, results, end) = try Recorder.read(url: url)
        #expect(header.backend == "fixture")
        #expect(header.host.name == "")
        #expect(header.expected.count == 3)
        #expect(results.count == 3)
        #expect(results[1].caseID == "case-1")
        #expect(results[1].result.content == "bravo")
        #expect(results[1].result.tokensOut == 9)
        #expect(results[1].result.assetIDs == ["asset-1"])
        // The sample case declares contains("AFE"); "bravo" does not contain it.
        #expect(results[1].checks.first?.name == "contains")
        #expect(results[1].checks.first?.arg == "AFE")
        #expect(results[1].checks.first?.pass == false)
        #expect(results[1].checks.first?.reason == "not found")
        #expect(end?.count == 3)
    }

    @Test("a tampered content byte names its seq")
    func tamperNamesSeq() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        var lines = try readLines(url)
        // Same length, so only the content changes; the stored sha256 no longer fits.
        lines[2] = lines[2].replacingOccurrences(of: #""content":"bravo""#, with: #""content":"bravX""#)
        try writeLines(lines, to: url)

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure == "hash mismatch at seq 2")
    }

    @Test("whitespace in a line is non-canonical at its seq")
    func whitespaceIsNonCanonical() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        var lines = try readLines(url)
        lines[1] = "{ " + String(lines[1].dropFirst())
        try writeLines(lines, to: url)

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure == "non-canonical at seq 1")
    }

    @Test("a file without a trailer is incomplete")
    func missingTrailer() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        var lines = try readLines(url)
        lines.removeLast()
        try writeLines(lines, to: url)

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure == "incomplete")
    }

    @Test("a missing expected (caseID, rep) fails membership")
    func missingExpectedPair() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        var aCase = sampleCase("alpha")
        aCase.repeat = 2

        let recorder = try Recorder(url: url, force: false)
        try recorder.writeHeader(
            runID: "run-1", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: Recorder.casesSHA256([aCase]),
            expected: [ExpectedEntry(caseID: "alpha", repeatCount: 2)])
        // Only rep 0 is written; rep 1 never ran.
        try recorder.writeResult(
            runID: "run-1", ts: "t1", caseID: "alpha", rep: 0,
            requestSHA256: Recorder.requestSHA256(for: aCase),
            result: sampleResult("alpha"), checks: [])
        try recorder.writeEnd(runID: "run-1", ts: "t2")

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure == "missing result for alpha rep 1")
    }

    @Test("a trailer count that does not match the results fails")
    func countMismatch() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        var lines = try readLines(url)
        // Rewrite the trailer with count 2 and a matching hash, so only the count is wrong.
        var end = EndRecord.fromJSON(try Canonical.parse(Data(lines[4].utf8)))!
        end.count = 2
        end.sha256 = Recorder.seal(end.toJSON())
        lines[4] = Canonical.string(of: end.toJSON())
        try writeLines(lines, to: url)

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure == "count mismatch: trailer says 2, file has 3")
    }

    @Test("a result record with a runID that does not match the header fails")
    func verifyRejectsMixedRunIDs() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)

        var lines = try readLines(url)
        // Rewrite result at seq 2 with a different runID, then reseal the chain from there on
        // (its own hash, then every later record's prev and hash) using the existing helpers.
        var result = ResultRecord.fromJSON(try Canonical.parse(Data(lines[2].utf8)))!
        result.runID = "other-run"
        result.sha256 = Recorder.seal(result.toJSON())
        lines[2] = Canonical.string(of: result.toJSON())

        var prevSHA = result.sha256
        for index in 3..<lines.count {
            let value = try Canonical.parse(Data(lines[index].utf8))
            if value["type"]?.stringValue == "end" {
                var end = EndRecord.fromJSON(value)!
                end.prev = prevSHA
                end.sha256 = Recorder.seal(end.toJSON())
                lines[index] = Canonical.string(of: end.toJSON())
                prevSHA = end.sha256
            } else {
                var record = ResultRecord.fromJSON(value)!
                record.prev = prevSHA
                record.sha256 = Recorder.seal(record.toJSON())
                lines[index] = Canonical.string(of: record.toJSON())
                prevSHA = record.sha256
            }
        }
        try writeLines(lines, to: url)

        let outcome = Recorder.verify(url: url)
        #expect(!outcome.ok)
        #expect(outcome.failure?.contains("runID") == true, "\(outcome.failure ?? "")")
    }

    @Test("an invalid expected entry (empty caseID or repeat out of range) fails without trapping")
    func verifyRejectsInvalidExpectedEntries() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        let recorder = try Recorder(url: url, force: false)
        try recorder.writeHeader(
            runID: "run-1", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: "x",
            expected: [ExpectedEntry(caseID: "", repeatCount: 1), ExpectedEntry(caseID: "beta", repeatCount: 0)])
        try recorder.writeEnd(runID: "run-1", ts: "t1")

        let result = Recorder.verify(url: url)
        #expect(!result.ok)
        #expect(result.failure?.contains("bad expected entry") == true, "\(result.failure ?? "")")
    }
}

// MARK: - Strict receipt shape (Codex review 0602 #1, #7)

/// Parse a recording, apply `edit` to the record at `seq`, then reseal the chain from there on.
private func rewrite(_ url: URL, seq: Int, _ edit: (JSONValue) -> JSONValue) throws {
    var values = try readLines(url).map { try Canonical.parse(Data($0.utf8)) }
    values[seq] = edit(values[seq])
    var prev = seq == 0 ? "" : (values[seq - 1]["sha256"]?.stringValue ?? "")
    for index in seq..<values.count {
        var value = values[index].setting("prev", to: .string(prev))
        value = value.setting("sha256", to: .string(Recorder.seal(value)))
        values[index] = value
        prev = value["sha256"]?.stringValue ?? ""
    }
    try writeLines(values.map { Canonical.string(of: $0) }, to: url)
}

private func removing(_ key: String, from value: JSONValue) -> JSONValue {
    .object((value.objectMembers ?? []).filter { $0.key != key })
}

private struct ShapeCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let seq: Int
    let expected: String
    let edit: @Sendable (JSONValue) -> JSONValue
}

private let shapeCases: [ShapeCase] = [
    ShapeCase(testDescription: "unknown field on a result", seq: 2, expected: "unknown field extra at seq 2") {
        $0.setting("extra", to: .int(1))
    },
    ShapeCase(testDescription: "unknown field on the header", seq: 0, expected: "unknown field extra at seq 0") {
        $0.setting("extra", to: .string("x"))
    },
    ShapeCase(testDescription: "unknown field on the trailer", seq: 4, expected: "unknown field extra at seq 4") {
        $0.setting("extra", to: .null)
    },
    ShapeCase(testDescription: "error is a number", seq: 1, expected: "bad field error at seq 1") {
        $0.setting("error", to: .int(123))
    },
    ShapeCase(testDescription: "error is not a known kind", seq: 1, expected: "bad field error at seq 1") {
        $0.setting("error", to: .string("nope"))
    },
    ShapeCase(testDescription: "tokens is a bool", seq: 1, expected: "bad field tokens at seq 1") {
        $0.setting("tokens", to: .bool(false))
    },
    ShapeCase(testDescription: "tokens.in is a string", seq: 1, expected: "bad field tokens.in at seq 1") {
        $0.setting("tokens", to: $0["tokens"]!.setting("in", to: .string("7")))
    },
    ShapeCase(testDescription: "tokens lacks an explicit null", seq: 1, expected: "missing field tokens.cached at seq 1") {
        $0.setting("tokens", to: removing("cached", from: $0["tokens"]!))
    },
    ShapeCase(testDescription: "errorDetail is absent", seq: 3, expected: "missing field errorDetail at seq 3") {
        removing("errorDetail", from: $0)
    },
    ShapeCase(testDescription: "an assetID is a number", seq: 1, expected: "bad field assetIDs[0] at seq 1") {
        $0.setting("assetIDs", to: .array([.int(1)]))
    },
    ShapeCase(testDescription: "wallMs is fractional", seq: 1, expected: "bad field wallMs at seq 1") {
        $0.setting("wallMs", to: .double(12.5))
    },
    ShapeCase(testDescription: "a check lacks reason", seq: 1, expected: "missing field checks[0].reason at seq 1") {
        $0.setting("checks", to: .array([removing("reason", from: $0["checks"]!.arrayValue![0])]))
    },
    ShapeCase(testDescription: "a check's pass is a string", seq: 1, expected: "bad field checks[0].pass at seq 1") {
        $0.setting("checks", to: .array([$0["checks"]!.arrayValue![0].setting("pass", to: .string("true"))]))
    },
    ShapeCase(testDescription: "host.chip is absent", seq: 0, expected: "missing field host.chip at seq 0") {
        $0.setting("host", to: removing("chip", from: $0["host"]!))
    },
    ShapeCase(testDescription: "an expected repeat is a string", seq: 0, expected: "bad field expected[1].repeat at seq 0") {
        var entries = $0["expected"]!.arrayValue!
        entries[1] = entries[1].setting("repeat", to: .string("1"))
        return $0.setting("expected", to: .array(entries))
    },
    ShapeCase(testDescription: "trailer count is a string", seq: 4, expected: "bad field count at seq 4") {
        $0.setting("count", to: .string("3"))
    },
    ShapeCase(testDescription: "a check appears twice on one record", seq: 1, expected: "duplicate check contains:AFE at seq 1") {
        let check = $0["checks"]!.arrayValue![0]
        return $0.setting("checks", to: .array([check, check]))
    },
]

@Suite("Strict receipt shape")
struct ReceiptShapeTests {

    @Test("verify names the first malformed field and its seq", arguments: shapeCases)
    fileprivate func malformed(_ shape: ShapeCase) throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        try rewrite(url, seq: shape.seq, shape.edit)

        let outcome = Recorder.verify(url: url)
        #expect(!outcome.ok)
        #expect(outcome.failure == shape.expected)
    }

    @Test("a reseal that changes nothing still verifies")
    func resealIsNeutral() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        try rewrite(url, seq: 0) { $0 }
        #expect(Recorder.verify(url: url) == VerifyResult(ok: true, count: 3))
    }

    @Test("a rep that drops a check the first rep carried fails")
    func checkSetDiffersAcrossReps() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        let aCase = Case(
            id: "twice", prompt: "What is an AFE?", format: .text, repeat: 2,
            checks: [.contains("AFE"), .notContains("blocked")])
        let recorder = try Recorder(url: url, force: false)
        try recorder.writeHeader(
            runID: "run-1", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: Recorder.casesSHA256([aCase]),
            expected: [ExpectedEntry(caseID: aCase.id, repeatCount: 2)])
        for rep in 0..<2 {
            let result = sampleResult("AFE")
            try recorder.writeResult(
                runID: "run-1", ts: "t1", caseID: aCase.id, rep: rep,
                requestSHA256: Recorder.requestSHA256(for: aCase), result: result,
                checks: zip(aCase.checks, Checks.evaluateAll(aCase, on: result)).map(CheckRecord.init))
        }
        try recorder.writeEnd(runID: "run-1", ts: "t2")
        #expect(Recorder.verify(url: url).ok)

        try rewrite(url, seq: 2) {
            $0.setting("checks", to: .array([$0["checks"]!.arrayValue![0]]))
        }
        #expect(Recorder.verify(url: url).failure == "check set differs for twice at seq 2")
    }
}

// MARK: - Output file policy (SPEC §6)

@Suite("Recorder output file")
struct RecorderFileTests {

    @Test("an existing file without --force throws exists")
    func existsWithoutForce() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        #expect(throws: RecorderError.exists) {
            _ = try Recorder(url: url, force: false)
        }
    }

    @Test("--force overwrites")
    func forceOverwrites() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        #expect(try readLines(url).count == 5)

        let recorder = try Recorder(url: url, force: true)
        try recorder.writeHeader(
            runID: "run-2", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: "x", expected: [])
        try recorder.writeEnd(runID: "run-2", ts: "t1")

        let lines = try readLines(url)
        #expect(lines.count == 2)
        let result = Recorder.verify(url: url)
        #expect(result.ok, "\(result.failure ?? "")")
        #expect(result.count == 0)
    }

    @Test("the recorder creates missing parent directories")
    func createsDirectories() throws {
        let url = scratchDir().appendingPathComponent("nested/deeper/run.jsonl")
        let recorder = try Recorder(url: url, force: false)
        try recorder.writeHeader(
            runID: "run-3", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: "x", expected: [])
        try recorder.writeEnd(runID: "run-3", ts: "t1")
        #expect(Recorder.verify(url: url).ok)
    }

    @Test("init without force refuses an existing file (exclusive create)")
    func initWithoutForceRefusesExistingFile() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        #expect(throws: RecorderError.exists) {
            _ = try Recorder(url: url, force: false)
        }
        // The original recording must be untouched by the failed attempt.
        #expect(try readLines(url).count == 5)
    }

    @Test("init with force truncates the existing file")
    func initWithForceTruncates() throws {
        let url = scratchDir().appendingPathComponent("run.jsonl")
        try writeRecording(at: url)
        #expect(try readLines(url).count == 5)

        let recorder = try Recorder(url: url, force: true)
        try recorder.writeHeader(
            runID: "run-4", ts: "t0", host: sampleHost, backend: "fixture",
            casesSHA256: "x", expected: [])
        try recorder.writeEnd(runID: "run-4", ts: "t1")

        let lines = try readLines(url)
        #expect(lines.count == 2)
        #expect(Recorder.verify(url: url).ok)
    }

    // writeEndPropagatesCloseFailure: skipped — FileHandle.close() cannot be cheaply provoked
    // to fail a second time from Swift Testing without private API; deinit's `try?` is already
    // guarded by `closed` so a normal double-close cannot happen via the public surface.
}
