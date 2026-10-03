// SPEC §5 and §7 — diff: classification, preconditions, medians, and the day-2 fixtures.
import Foundation
import Testing
@testable import SeptdriftCore

// MARK: - Helpers

private func scratch() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("septdrift-diff-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let host = HostInfo(os: "macOS 27.0", osBuild: "27A100", chip: "Apple M1", name: "")

/// Write one recording from cases plus a per-(case, rep) result. Checks are the real
/// `Checks.evaluateAll` outcomes, so the records are shaped exactly like a real run.
@discardableResult
private func makeRecording(
    at url: URL,
    cases: [Case],
    backend: String = "fixture",
    casesHash: String? = nil,
    requestHash: ((Case) -> String)? = nil,
    complete: Bool = true,
    result: (Case, Int) -> Result
) throws -> URL {
    let recorder = try Recorder(url: url, force: true)
    let runID = UUID().uuidString
    try recorder.writeHeader(
        runID: runID, ts: "2026-09-22T00:00:00Z", host: host, backend: backend,
        casesSHA256: casesHash ?? Recorder.casesSHA256(cases),
        expected: cases.map { ExpectedEntry(caseID: $0.id, repeatCount: $0.repeat) })
    for aCase in cases {
        for rep in 0..<aCase.repeat {
            let value = result(aCase, rep)
            let checks = zip(aCase.checks, Checks.evaluateAll(aCase, on: value))
                .map { CheckRecord($0, $1) }
            try recorder.writeResult(
                runID: runID, ts: "2026-09-22T00:00:01Z", caseID: aCase.id, rep: rep,
                requestSHA256: requestHash?(aCase) ?? Recorder.requestSHA256(for: aCase),
                result: value, checks: checks)
        }
    }
    if complete { try recorder.writeEnd(runID: runID, ts: "2026-09-22T00:00:02Z") }
    return url
}

private func textCase(
    _ id: String, needle: String = "ok", repeat reps: Int = 1
) -> Case {
    Case(id: id, prompt: "p", repeat: reps, checks: [.contains(needle)])
}

private func ok(_ content: String, wallMs: Int = 100, tokensOut: Int? = 10) -> Result {
    Result(content: content, wallMs: wallMs, tokensOut: tokensOut, assetIDs: ["asset-1"])
}

private func classes(_ card: Scorecard) -> [String: DiffClass] {
    Dictionary(uniqueKeysWithValues: card.rows.map { ("\($0.caseID)|\($0.check)", $0.klass) })
}

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // SeptdriftCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root

// MARK: - Classification

@Test func flipIsRateOneToBelowOne() throws {
    let dir = scratch()
    let cases = [textCase("c1")]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, _ in
        ok("all ok here")
    }
    let b = try makeRecording(at: dir.appendingPathComponent("b.jsonl"), cases: cases) { _, _ in
        ok("nothing matched")
    }
    let card = try Diff.diff(a: a, b: b, options: DiffOptions())
    #expect(card.rows.count == 1)
    #expect(card.rows[0].klass == .flip)
    #expect(card.rows[0].rateA == 1.0)
    #expect(card.rows[0].rateB == 0.0)
    #expect(card.counts.flips == 1)
    #expect(card.exitCode == 1)
}

@Test func fixIsBelowOneToOneAndFailOnFix() throws {
    let dir = scratch()
    let cases = [textCase("c1", repeat: 2)]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, rep in
        ok(rep == 0 ? "ok" : "no")
    }
    let b = try makeRecording(at: dir.appendingPathComponent("b.jsonl"), cases: cases) { _, _ in
        ok("ok")
    }
    let card = try Diff.diff(a: a, b: b, options: DiffOptions())
    #expect(card.rows[0].klass == .fix)
    #expect(card.rows[0].rateA == 0.5)
    #expect(card.counts.fixes == 1)
    #expect(card.exitCode == 0)

    let strict = try Diff.diff(a: a, b: b, options: DiffOptions(failOnFix: true))
    #expect(strict.exitCode == 1)
}

@Test func degradeAndImprovedStayBelowOne() throws {
    let dir = scratch()
    let cases = [textCase("c1", repeat: 4)]
    // A: 3/4 pass. B: 1/4 pass -> degrade (rateA < 1, rateB < rateA).
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, rep in
        ok(rep == 3 ? "no" : "ok")
    }
    let b = try makeRecording(at: dir.appendingPathComponent("b.jsonl"), cases: cases) { _, rep in
        ok(rep == 0 ? "ok" : "no")
    }
    let degraded = try Diff.diff(a: a, b: b, options: DiffOptions())
    #expect(degraded.rows[0].klass == .degrade)
    #expect(degraded.counts.degrades == 1)
    #expect(degraded.exitCode == 0)

    // Reversed: 1/4 -> 3/4 is an improvement that is not a fix.
    let improved = try Diff.diff(a: b, b: a, options: DiffOptions())
    #expect(improved.rows[0].klass == .improved)
    #expect(improved.counts == DiffCounts(improved: 1))
    #expect(improved.counts.total == improved.rows.count)
    #expect(degraded.counts.total == degraded.rows.count)
    #expect(improved.exitCode == 0)
}

@Test func unchangedWhenRatesMatch() throws {
    let dir = scratch()
    let cases = [textCase("c1", repeat: 2)]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, rep in
        ok(rep == 0 ? "ok" : "no")
    }
    let b = try makeRecording(at: dir.appendingPathComponent("b.jsonl"), cases: cases) { _, rep in
        ok(rep == 1 ? "ok" : "no")
    }
    let card = try Diff.diff(a: a, b: b, options: DiffOptions())
    #expect(card.rows[0].klass == .unchanged)
    #expect(card.counts.unchanged == 1)
    #expect(card.exitCode == 0)
}

@Test func unpairedCasesAreOnlyInLists() throws {
    let dir = scratch()
    let a = try makeRecording(
        at: dir.appendingPathComponent("a.jsonl"),
        cases: [textCase("c1"), textCase("onlyA")],
        casesHash: "same") { _, _ in ok("ok") }
    let b = try makeRecording(
        at: dir.appendingPathComponent("b.jsonl"),
        cases: [textCase("c1"), textCase("onlyB")],
        casesHash: "same") { _, _ in ok("ok") }
    let card = try Diff.diff(a: a, b: b, options: DiffOptions())
    #expect(card.onlyInA == ["onlyA"])
    #expect(card.onlyInB == ["onlyB"])
    #expect(card.rows.map(\.caseID) == ["c1"])
    #expect(card.counts.unchanged == 1)
    #expect(card.exitCode == 0)
}

@Test func checkAddedAndRemovedAreNotCounted() throws {
    let dir = scratch()
    let shared = Case(id: "c1", prompt: "p", checks: [.contains("ok"), .maxWallMs(1000)])
    let changed = Case(id: "c1", prompt: "p", checks: [.contains("ok"), .maxOutputTokens(5)])
    let a = try makeRecording(
        at: dir.appendingPathComponent("a.jsonl"), cases: [shared], casesHash: "same"
    ) { _, _ in ok("ok") }
    let b = try makeRecording(
        at: dir.appendingPathComponent("b.jsonl"), cases: [changed], casesHash: "same"
    ) { _, _ in ok("ok") }
    let card = try Diff.diff(a: a, b: b, options: DiffOptions())
    let byClass = classes(card)
    #expect(byClass["c1|max_wall_ms:1000"] == .removed)
    #expect(byClass["c1|max_output_tokens:5"] == .added)
    #expect(byClass["c1|contains:ok"] == .unchanged)
    #expect(card.counts == DiffCounts(unchanged: 1, added: 1, removed: 1))
    #expect(card.counts.total == card.rows.count)
    #expect(card.exitCode == 0)
}

// MARK: - Preconditions

@Test func differentCasesHashNeedsTheDriftFlag() throws {
    let dir = scratch()
    let cases = [textCase("c1")]
    let a = try makeRecording(
        at: dir.appendingPathComponent("a.jsonl"), cases: cases, casesHash: "hash-a"
    ) { _, _ in ok("ok") }
    let b = try makeRecording(
        at: dir.appendingPathComponent("b.jsonl"), cases: cases, casesHash: "hash-b"
    ) { _, _ in ok("ok") }

    #expect(throws: DiffError.casesChanged(a: "hash-a", b: "hash-b")) {
        _ = try Diff.diff(a: a, b: b, options: DiffOptions())
    }
}

@Test func requestDriftExcludesThePairWithTheFlag() throws {
    let dir = scratch()
    let cases = [textCase("drifted"), textCase("stable")]
    let a = try makeRecording(
        at: dir.appendingPathComponent("a.jsonl"), cases: cases, casesHash: "hash-a",
        requestHash: { _ in "req-1" }
    ) { _, _ in ok("ok") }
    let b = try makeRecording(
        at: dir.appendingPathComponent("b.jsonl"), cases: cases, casesHash: "hash-b",
        requestHash: { $0.id == "drifted" ? "req-2" : "req-1" }
    ) { aCase, _ in ok(aCase.id == "drifted" ? "no" : "ok") }

    let card = try Diff.diff(a: a, b: b, options: DiffOptions(allowRequestDrift: true))
    #expect(card.requestChanged == ["drifted"])
    #expect(card.rows.map(\.caseID) == ["stable"])
    #expect(card.counts.flips == 0)
    #expect(card.exitCode == 0)
}

@Test func incompleteSideIsAnError() throws {
    let dir = scratch()
    let cases = [textCase("c1")]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, _ in
        ok("ok")
    }
    let b = try makeRecording(
        at: dir.appendingPathComponent("b.jsonl"), cases: cases, complete: false
    ) { _, _ in ok("ok") }

    #expect(throws: DiffError.incomplete(side: "B")) {
        _ = try Diff.diff(a: a, b: b, options: DiffOptions())
    }
}

@Test func tamperedSideIsAnError() throws {
    let dir = scratch()
    let cases = [textCase("c1")]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, _ in
        ok("okay")
    }
    let b = try makeRecording(at: dir.appendingPathComponent("b.jsonl"), cases: cases) { _, _ in
        ok("okay")
    }
    // Same length, so only the hash notices.
    var text = try String(contentsOf: a, encoding: .utf8)
    text = text.replacingOccurrences(of: "\"content\":\"okay\"", with: "\"content\":\"okky\"")
    try text.write(to: a, atomically: true, encoding: .utf8)

    let thrown = #expect(throws: DiffError.self) {
        _ = try Diff.diff(a: a, b: b, options: DiffOptions())
    }
    if case .notVerified(let side, let message)? = thrown {
        #expect(side == "A")
        #expect(message.contains("hash mismatch"))
    } else {
        Issue.record("expected notVerified, got \(String(describing: thrown))")
    }
}

// MARK: - Medians and error kinds

@Test func medianOddIsTheMiddleValue() {
    #expect(Diff.median([700, 600, 800]) == 700)
    #expect(Diff.median([]) == nil)
}

@Test func medianEvenIsTheMeanRoundedHalfUp() {
    #expect(Diff.median([12, 15]) == 14)        // 13.5 -> 14
    #expect(Diff.median([800, 1000]) == 900)
    #expect(Diff.median([12, 12, 12, 15, 18, 20]) == 14)
}

@Test func sideHeadersCarryMediansAndErrorKinds() throws {
    let dir = scratch()
    let cases = [
        Case(id: "good", prompt: "p", repeat: 3, checks: [.contains("ok")]),
        Case(id: "bad", prompt: "p", checks: [.expectError(.guardrail)]),
    ]
    let file = try makeRecording(
        at: dir.appendingPathComponent("a.jsonl"), cases: cases
    ) { aCase, rep in
        if aCase.id == "bad" {
            return Result(content: "", wallMs: 9999, tokensOut: 999,
                          assetIDs: ["asset-2"], error: .guardrail)
        }
        return ok("ok", wallMs: [100, 300, 200][rep], tokensOut: [10, 30, 20][rep])
    }
    let card = try Diff.diff(a: file, b: file, options: DiffOptions())
    let side = card.sides[0]
    #expect(side.backend == "fixture")
    #expect(side.chip == "Apple M1")
    #expect(side.osBuild == "27A100")
    #expect(side.assetIDs == ["asset-1", "asset-2"])
    #expect(side.medianWallMs == 200)       // error result excluded
    #expect(side.medianTokensOut == 20)
    #expect(side.errorKinds == ["guardrail": 1])
}

// MARK: - Day-2 fixtures, end to end

@Test func dayTwoFixturesMatchTheExpectedDiff() async throws {
    let cases = try CaseLoader.load(path: repoRoot.appendingPathComponent("cases/day2.yaml").path)
    let dir = scratch()

    func build(_ fixture: String, _ name: String) async throws -> URL {
        let backend = try FixtureBackend(
            fileURL: repoRoot.appendingPathComponent("fixtures/\(fixture)"))
        let url = dir.appendingPathComponent(name)
        let recorder = try Recorder(url: url, force: true)
        let runID = UUID().uuidString
        try recorder.writeHeader(
            runID: runID, ts: "2026-09-22T00:00:00Z", host: host, backend: backend.name,
            casesSHA256: Recorder.casesSHA256(cases),
            expected: cases.map { ExpectedEntry(caseID: $0.id, repeatCount: $0.repeat) })
        for aCase in cases {
            for rep in 0..<aCase.repeat {
                let value = try await backend.respond(to: aCase, rep: rep)
                let checks = zip(aCase.checks, Checks.evaluateAll(aCase, on: value))
                    .map { CheckRecord($0, $1) }
                try recorder.writeResult(
                    runID: runID, ts: "2026-09-22T00:00:01Z", caseID: aCase.id, rep: rep,
                    requestSHA256: Recorder.requestSHA256(for: aCase),
                    result: value, checks: checks)
            }
        }
        try recorder.writeEnd(runID: runID, ts: "2026-09-22T00:00:02Z")
        return url
    }

    let a = try await build("side-a.jsonl", "side-a.jsonl")
    let b = try await build("side-b.jsonl", "side-b.jsonl")

    #expect(Recorder.verify(url: a).ok)
    #expect(Recorder.verify(url: b).ok)

    let card = try Diff.diff(a: a, b: b, options: DiffOptions())

    // Derived from fixtures/expected-diff.md (the authoritative day-2 expectation).
    let expected: [String: DiffClass] = [
        "afe-no-context|contains:Authorization for Expenditure": .flip,
        "afe-no-context|max_wall_ms:3000": .unchanged,
        "afe-with-context|contains:Authorization for Expenditure": .flip,
        "afe-with-context|max_wall_ms:3000": .flip,
        "ordered-json|json_field_equals:kind=request": .unchanged,
        "ordered-json|json_field_equals:count=3": .flip,
        "ordered-json|json_field_equals:approved=true": .unchanged,
        "repeat-ready|contains:Ready for review": .flip,
        "repeat-ready|max_wall_ms:1500": .unchanged,
        "guardrail-error|expect_error:guardrail": .unchanged,
        #"status-summary|regex:^Status: ready\.$"#: .unchanged,
        "status-summary|not_contains:blocked": .unchanged,
        "status-summary|max_output_tokens:40": .unchanged,
    ]
    #expect(classes(card) == expected)
    #expect(card.onlyInA.isEmpty)
    #expect(card.onlyInB.isEmpty)
    #expect(card.requestChanged.isEmpty)
    #expect(card.counts == DiffCounts(flips: 5, degrades: 0, fixes: 0, unchanged: 8))
    #expect(card.exitCode == 1)

    // Header block, per expected-diff.md.
    #expect(card.sides[0].assetIDs == ["fixture-model-1"])
    #expect(card.sides[1].assetIDs == ["fixture-model-1"])
    #expect(card.sides[0].medianWallMs == 900)
    #expect(card.sides[1].medianWallMs == 900)
    #expect(card.sides[0].medianTokensOut == 15)
    #expect(card.sides[1].medianTokensOut == 14)   // 13.5 rounded half up
    #expect(card.sides[0].errorKinds == ["guardrail": 1])
    #expect(card.sides[1].errorKinds == ["guardrail": 1, "context": 1])

    // repeat-ready is 3/3 -> 2/3.
    let repeatRow = try #require(card.rows.first {
        $0.caseID == "repeat-ready" && $0.check == "contains:Ready for review"
    })
    #expect(repeatRow.passesA == 3 && repeatRow.repsA == 3)
    #expect(repeatRow.passesB == 2 && repeatRow.repsB == 3)

    let text = Diff.render(card)
    #expect(text.contains("side A: backend=fixture"))
    #expect(text.contains("2/3"))
    #expect(text.contains("counts: flips=5 degrades=0 fixes=0 unchanged=8 improved=0 added=0 removed=0\n"))
    #expect(text.contains("exit: 1"))
}

@Test func jsonEncodingRoundTripsTheScorecard() throws {
    let dir = scratch()
    let cases = [textCase("c1")]
    let a = try makeRecording(at: dir.appendingPathComponent("a.jsonl"), cases: cases) { _, _ in
        ok("ok")
    }
    let card = try Diff.diff(a: a, b: a, options: DiffOptions())
    let data = try JSONEncoder().encode(card)
    let any = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(any?["exitCode"] as? Int == 0)
    #expect((any?["rows"] as? [Any])?.count == 1)
}

@Test func jsonCarriesDelta() throws {
    let withDelta = Row(
        caseID: "c1", check: "contains:ok", rateA: 1.0, rateB: 0.5, klass: .degrade)
    let dataWithDelta = try JSONEncoder().encode(withDelta)
    let anyWithDelta = try JSONSerialization.jsonObject(with: dataWithDelta) as? [String: Any]
    #expect(anyWithDelta?["delta"] as? Double == -0.5)

    let withoutB = Row(
        caseID: "c1", check: "contains:ok", rateA: 1.0, rateB: nil, klass: .removed)
    let dataWithoutB = try JSONEncoder().encode(withoutB)
    let anyWithoutB = try JSONSerialization.jsonObject(with: dataWithoutB) as? [String: Any]
    #expect(anyWithoutB?["delta"] is NSNull)
}

@Test func medianLargeIntegersDoesNotOverflow() {
    #expect(Diff.median([Int.max, Int.max - 1]) == Int.max)
    #expect(Diff.median([Int.max, Int.max]) == Int.max)
}
