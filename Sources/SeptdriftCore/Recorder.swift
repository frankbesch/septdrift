// SPEC §3 — the recording: `receipt/0.2` JSONL, one `run` header, N `result` records,
// one `end` trailer, hash-chained over canonical bytes.
import Foundation

/// Schema tag written on every record.
public enum Receipt {
    public static let schema = "receipt/0.2"
}

public enum RecorderError: Error, Equatable {
    /// `--out` exists and `--force` was not given (SPEC §6, exit 4).
    case exists
    case cannotCreate(String)
    case io(String)
}

// MARK: - Pieces

/// `host {os, osBuild, chip, name}` (SPEC §3). `--no-hostname` makes `name` "".
public struct HostInfo: Sendable, Equatable {
    public var os: String
    public var osBuild: String
    public var chip: String
    public var name: String

    public init(os: String, osBuild: String, chip: String, name: String) {
        self.os = os
        self.osBuild = osBuild
        self.chip = chip
        self.name = name
    }

    public func toJSON() -> JSONValue {
        .obj([
            ("os", .string(os)),
            ("osBuild", .string(osBuild)),
            ("chip", .string(chip)),
            ("name", .string(name)),
        ])
    }

    public static func fromJSON(_ value: JSONValue) -> HostInfo? {
        guard let os = value["os"]?.stringValue,
              let build = value["osBuild"]?.stringValue,
              let chip = value["chip"]?.stringValue,
              let name = value["name"]?.stringValue
        else { return nil }
        return HostInfo(os: os, osBuild: build, chip: chip, name: name)
    }
}

/// One `expected` entry of the header: a case and how many reps it declares.
public struct ExpectedEntry: Sendable, Equatable {
    public var caseID: String
    public var repeatCount: Int

    public init(caseID: String, repeatCount: Int) {
        self.caseID = caseID
        self.repeatCount = repeatCount
    }

    public func toJSON() -> JSONValue {
        .obj([("caseID", .string(caseID)), ("repeat", .int(repeatCount))])
    }

    public static func fromJSON(_ value: JSONValue) -> ExpectedEntry? {
        guard let id = value["caseID"]?.stringValue, let n = value["repeat"]?.intValue
        else { return nil }
        return ExpectedEntry(caseID: id, repeatCount: n)
    }
}

/// One scored check on a result record: `{name, arg, pass, reason}`.
public struct CheckRecord: Sendable, Equatable {
    public var name: String
    public var arg: String
    public var pass: Bool
    /// null when the check passed.
    public var reason: String?

    public init(name: String, arg: String, pass: Bool, reason: String? = nil) {
        self.name = name
        self.arg = arg
        self.pass = pass
        self.reason = reason
    }

    public init(_ check: Check, _ outcome: Outcome) {
        self.init(name: check.name, arg: check.arg, pass: outcome.pass, reason: outcome.reason)
    }

    public func toJSON() -> JSONValue {
        .obj([
            ("name", .string(name)),
            ("arg", .string(arg)),
            ("pass", .bool(pass)),
            ("reason", .stringOrNull(reason)),
        ])
    }

    public static func fromJSON(_ value: JSONValue) -> CheckRecord? {
        guard let name = value["name"]?.stringValue,
              let arg = value["arg"]?.stringValue,
              let pass = value["pass"]?.boolValue
        else { return nil }
        return CheckRecord(name: name, arg: arg, pass: pass, reason: value["reason"]?.stringValue)
    }
}

// MARK: - Records

public struct RunHeader: Sendable, Equatable {
    public var runID: String
    public var seq: Int
    public var ts: String
    public var host: HostInfo
    public var backend: String
    public var casesSHA256: String
    public var expected: [ExpectedEntry]
    public var prev: String
    public var sha256: String

    public init(
        runID: String, seq: Int = 0, ts: String, host: HostInfo, backend: String,
        casesSHA256: String, expected: [ExpectedEntry], prev: String = "", sha256: String = ""
    ) {
        self.runID = runID
        self.seq = seq
        self.ts = ts
        self.host = host
        self.backend = backend
        self.casesSHA256 = casesSHA256
        self.expected = expected
        self.prev = prev
        self.sha256 = sha256
    }

    public func toJSON() -> JSONValue {
        .obj([
            ("schema", .string(Receipt.schema)),
            ("type", .string("run")),
            ("runID", .string(runID)),
            ("seq", .int(seq)),
            ("ts", .string(ts)),
            ("host", host.toJSON()),
            ("backend", .string(backend)),
            ("casesSHA256", .string(casesSHA256)),
            ("expected", .array(expected.map { $0.toJSON() })),
            ("prev", .string(prev)),
            ("sha256", .string(sha256)),
        ])
    }

    public static func fromJSON(_ v: JSONValue) -> RunHeader? {
        guard let runID = v["runID"]?.stringValue,
              let seq = v["seq"]?.intValue,
              let ts = v["ts"]?.stringValue,
              let hostValue = v["host"], let host = HostInfo.fromJSON(hostValue),
              let backend = v["backend"]?.stringValue,
              let casesHash = v["casesSHA256"]?.stringValue,
              let expectedList = v["expected"]?.arrayValue,
              let prev = v["prev"]?.stringValue,
              let sha = v["sha256"]?.stringValue
        else { return nil }
        let expected = expectedList.compactMap(ExpectedEntry.fromJSON)
        guard expected.count == expectedList.count else { return nil }
        return RunHeader(
            runID: runID, seq: seq, ts: ts, host: host, backend: backend,
            casesSHA256: casesHash, expected: expected, prev: prev, sha256: sha)
    }
}

public struct ResultRecord: Sendable, Equatable {
    public var runID: String
    public var seq: Int
    public var ts: String
    public var caseID: String
    /// 0-based (SPEC §3).
    public var rep: Int
    public var requestSHA256: String
    public var result: Result
    public var checks: [CheckRecord]
    public var prev: String
    public var sha256: String

    public init(
        runID: String, seq: Int, ts: String, caseID: String, rep: Int,
        requestSHA256: String, result: Result, checks: [CheckRecord],
        prev: String = "", sha256: String = ""
    ) {
        self.runID = runID
        self.seq = seq
        self.ts = ts
        self.caseID = caseID
        self.rep = rep
        self.requestSHA256 = requestSHA256
        self.result = result
        self.checks = checks
        self.prev = prev
        self.sha256 = sha256
    }

    public func toJSON() -> JSONValue {
        .obj([
            ("schema", .string(Receipt.schema)),
            ("type", .string("result")),
            ("runID", .string(runID)),
            ("seq", .int(seq)),
            ("ts", .string(ts)),
            ("caseID", .string(caseID)),
            ("rep", .int(rep)),
            ("requestSHA256", .string(requestSHA256)),
            ("content", .string(result.content)),
            ("error", .stringOrNull(result.error?.rawValue)),
            ("errorDetail", .stringOrNull(result.errorDetail)),
            ("wallMs", .int(result.wallMs)),
            ("tokens", .obj([
                ("in", .intOrNull(result.tokensIn)),
                ("cached", .intOrNull(result.tokensCached)),
                ("out", .intOrNull(result.tokensOut)),
                ("reasoning", .intOrNull(result.tokensReasoning)),
            ])),
            ("assetIDs", .array(result.assetIDs.map { .string($0) })),
            ("checks", .array(checks.map { $0.toJSON() })),
            ("prev", .string(prev)),
            ("sha256", .string(sha256)),
        ])
    }

    public static func fromJSON(_ v: JSONValue) -> ResultRecord? {
        guard let runID = v["runID"]?.stringValue,
              let seq = v["seq"]?.intValue,
              let ts = v["ts"]?.stringValue,
              let caseID = v["caseID"]?.stringValue,
              let rep = v["rep"]?.intValue,
              let requestHash = v["requestSHA256"]?.stringValue,
              let content = v["content"]?.stringValue,
              let wallMs = v["wallMs"]?.intValue,
              let tokens = v["tokens"],
              let assetList = v["assetIDs"]?.arrayValue,
              let checkList = v["checks"]?.arrayValue,
              let prev = v["prev"]?.stringValue,
              let sha = v["sha256"]?.stringValue
        else { return nil }
        var error: ErrorKind?
        if let raw = v["error"]?.stringValue {
            guard let kind = ErrorKind(rawValue: raw) else { return nil }
            error = kind
        }
        let result = Result(
            content: content,
            wallMs: wallMs,
            tokensIn: tokens["in"]?.intValue,
            tokensCached: tokens["cached"]?.intValue,
            tokensOut: tokens["out"]?.intValue,
            tokensReasoning: tokens["reasoning"]?.intValue,
            assetIDs: assetList.compactMap { $0.stringValue },
            error: error,
            errorDetail: v["errorDetail"]?.stringValue)
        let checks = checkList.compactMap(CheckRecord.fromJSON)
        guard checks.count == checkList.count else { return nil }
        return ResultRecord(
            runID: runID, seq: seq, ts: ts, caseID: caseID, rep: rep,
            requestSHA256: requestHash, result: result, checks: checks,
            prev: prev, sha256: sha)
    }
}

public struct EndRecord: Sendable, Equatable {
    public var runID: String
    public var seq: Int
    public var ts: String
    /// Number of result records in the file.
    public var count: Int
    public var prev: String
    public var sha256: String

    public init(
        runID: String, seq: Int, ts: String, count: Int,
        prev: String = "", sha256: String = ""
    ) {
        self.runID = runID
        self.seq = seq
        self.ts = ts
        self.count = count
        self.prev = prev
        self.sha256 = sha256
    }

    public func toJSON() -> JSONValue {
        .obj([
            ("schema", .string(Receipt.schema)),
            ("type", .string("end")),
            ("runID", .string(runID)),
            ("seq", .int(seq)),
            ("ts", .string(ts)),
            ("count", .int(count)),
            ("prev", .string(prev)),
            ("sha256", .string(sha256)),
        ])
    }

    public static func fromJSON(_ v: JSONValue) -> EndRecord? {
        guard let runID = v["runID"]?.stringValue,
              let seq = v["seq"]?.intValue,
              let ts = v["ts"]?.stringValue,
              let count = v["count"]?.intValue,
              let prev = v["prev"]?.stringValue,
              let sha = v["sha256"]?.stringValue
        else { return nil }
        return EndRecord(runID: runID, seq: seq, ts: ts, count: count, prev: prev, sha256: sha)
    }
}

/// The outcome of `verify` (SPEC §3): `OK n results`, or the first failure with its seq.
public struct VerifyResult: Sendable, Equatable {
    public let ok: Bool
    public let count: Int
    /// nil when `ok`.
    public let failure: String?

    public init(ok: Bool, count: Int, failure: String? = nil) {
        self.ok = ok
        self.count = count
        self.failure = failure
    }

    static func good(_ count: Int) -> VerifyResult { VerifyResult(ok: true, count: count) }
    static func bad(_ message: String) -> VerifyResult {
        VerifyResult(ok: false, count: 0, failure: message)
    }

    /// What `verify` prints. Exit 0 when `ok`, 1 otherwise.
    public var message: String { ok ? "OK \(count) results" : (failure ?? "failed") }
}

// MARK: - Recorder

/// Writes the recording. One instance per run; serialized by an internal lock so a
/// concurrent caller cannot interleave lines or break the chain.
public final class Recorder: @unchecked Sendable {

    private let lock = NSLock()
    private let handle: FileHandle
    private var nextSeq = 0
    private var prev = ""
    private var resultCount = 0
    private var closed = false

    public let url: URL

    /// `force` overwrites an existing file; without it an existing file is `RecorderError.exists`.
    /// The file is created exclusively (`O_EXCL` without `force`) so a concurrent creator cannot
    /// race the exists-check (Codex review 0602 #16).
    public init(url: URL, force: Bool) throws {
        self.url = url
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty, !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let flags: Int32 = force ? (O_WRONLY | O_CREAT | O_TRUNC) : (O_WRONLY | O_CREAT | O_EXCL)
        let fd = url.path.withCString { open($0, flags, 0o644) }
        if fd < 0 {
            if !force && errno == EEXIST { throw RecorderError.exists }
            throw RecorderError.cannotCreate(url.path)
        }
        self.handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    deinit { if !closed { try? handle.close() } }

    // MARK: Writing

    @discardableResult
    public func writeHeader(
        runID: String,
        ts: String,
        host: HostInfo,
        backend: String,
        casesSHA256: String,
        expected: [ExpectedEntry]
    ) throws -> RunHeader {
        lock.lock()
        defer { lock.unlock() }
        var header = RunHeader(
            runID: runID, seq: nextSeq, ts: ts, host: host, backend: backend,
            casesSHA256: casesSHA256, expected: expected, prev: prev)
        header.sha256 = Recorder.seal(header.toJSON())
        try emit(header.toJSON(), sha: header.sha256)
        return header
    }

    @discardableResult
    public func writeResult(
        runID: String,
        ts: String,
        caseID: String,
        rep: Int,
        requestSHA256: String,
        result: Result,
        checks: [CheckRecord]
    ) throws -> ResultRecord {
        lock.lock()
        defer { lock.unlock() }
        var record = ResultRecord(
            runID: runID, seq: nextSeq, ts: ts, caseID: caseID, rep: rep,
            requestSHA256: requestSHA256, result: result, checks: checks, prev: prev)
        record.sha256 = Recorder.seal(record.toJSON())
        try emit(record.toJSON(), sha: record.sha256)
        resultCount += 1
        return record
    }

    @discardableResult
    public func writeEnd(runID: String, ts: String) throws -> EndRecord {
        lock.lock()
        defer { lock.unlock() }
        var end = EndRecord(
            runID: runID, seq: nextSeq, ts: ts, count: resultCount, prev: prev)
        end.sha256 = Recorder.seal(end.toJSON())
        try emit(end.toJSON(), sha: end.sha256)
        closed = true
        do {
            try handle.close()
        } catch {
            throw RecorderError.io("close: \(String(describing: error))")
        }
        return end
    }

    /// SHA-256 over the canonical bytes of the record with `sha256: ""` (SPEC §3).
    static func seal(_ record: JSONValue) -> String {
        Canonical.sha256Hex(of: record.setting("sha256", to: .string("")))
    }

    /// One line = canonical bytes + "\n". The newline is never hashed.
    private func emit(_ record: JSONValue, sha: String) throws {
        if closed { throw RecorderError.io("recorder already closed") }
        var line = Canonical.bytes(of: record)
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
        } catch {
            throw RecorderError.io(String(describing: error))
        }
        nextSeq += 1
        prev = sha
    }

    // MARK: Request and cases hashes

    /// The hashed request shape: {instructions, context, prompt, format, schema, options},
    /// with `null` for every absent optional (SPEC §3).
    public static func requestJSON(for aCase: Case) -> JSONValue {
        .obj([
            ("instructions", .stringOrNull(aCase.instructions)),
            ("context", .stringOrNull(aCase.context)),
            ("prompt", .string(aCase.prompt)),
            ("format", .string(aCase.format.rawValue)),
            ("schema", schemaJSON(aCase.schema)),
            ("options", optionsJSON(aCase.options)),
        ])
    }

    public static func requestSHA256(for aCase: Case) -> String {
        Canonical.sha256Hex(of: requestJSON(for: aCase))
    }

    /// The hashed case shape: the request object plus `id`, `repeat` and `checks`.
    public static func caseJSON(_ aCase: Case) -> JSONValue {
        var members = requestJSON(for: aCase).objectMembers ?? []
        members.append(.init("id", .string(aCase.id)))
        members.append(.init("repeat", .int(aCase.repeat)))
        members.append(.init("checks", .array(aCase.checks.map {
            .obj([("name", .string($0.name)), ("arg", .string($0.arg))])
        })))
        return .object(members)
    }

    public static func casesJSON(_ cases: [Case]) -> JSONValue {
        .array(cases.map(caseJSON))
    }

    public static func casesSHA256(_ cases: [Case]) -> String {
        Canonical.sha256Hex(of: casesJSON(cases))
    }

    private static func schemaJSON(_ schema: [SchemaField]?) -> JSONValue {
        guard let schema else { return .null }
        // Ordered: property order is part of the request (SPEC §1).
        return .array(schema.map {
            .obj([
                ("name", .string($0.name)),
                ("kind", .string($0.kind.rawValue)),
                ("description", .stringOrNull($0.description)),
                ("optional", .bool($0.optional)),
            ])
        })
    }

    private static func optionsJSON(_ options: GenerationOptionsSpec?) -> JSONValue {
        guard let options else { return .null }
        return .obj([
            ("temperature", .doubleOrNull(options.temperature)),
            ("max_response_tokens", .intOrNull(options.maxResponseTokens)),
        ])
    }

    // MARK: - Reading and verifying

    /// Parse a recording back into records. Used by `diff`; does not verify hashes.
    public static func read(url: URL) throws -> (header: RunHeader, results: [ResultRecord], end: EndRecord?) {
        try read(data: try bytes(at: url))
    }

    /// `read` over bytes already in memory, so `diff` scores the snapshot it verified
    /// (Codex review 0602 #8).
    public static func read(data: Data) throws -> (header: RunHeader, results: [ResultRecord], end: EndRecord?) {
        let lines = self.lines(in: data).lines
        guard let first = lines.first,
              let headerValue = try? Canonical.parse(first),
              let header = RunHeader.fromJSON(headerValue),
              headerValue["type"]?.stringValue == "run"
        else { throw RecorderError.io("no run header") }

        var results: [ResultRecord] = []
        var end: EndRecord?
        for line in lines.dropFirst() {
            guard let value = try? Canonical.parse(line) else {
                throw RecorderError.io("unparsable line")
            }
            switch value["type"]?.stringValue {
            case "result":
                guard let record = ResultRecord.fromJSON(value) else {
                    throw RecorderError.io("bad result record")
                }
                results.append(record)
            case "end":
                guard let record = EndRecord.fromJSON(value) else {
                    throw RecorderError.io("bad end record")
                }
                end = record
            default:
                throw RecorderError.io("unknown record type")
            }
        }
        return (header, results, end)
    }

    /// SPEC §3 `verify`: every hash, the chain, seq contiguity, the trailer and its count,
    /// and that every expected (caseID, rep) appears exactly once.
    public static func verify(url: URL) -> VerifyResult {
        guard let data = try? bytes(at: url) else {
            return .bad("cannot read \(url.lastPathComponent)")
        }
        return verify(data: data)
    }

    /// `verify` over bytes already in memory (Codex review 0602 #8).
    public static func verify(data: Data) -> VerifyResult {
        let (lines, terminated) = self.lines(in: data)
        guard !lines.isEmpty else { return .bad("incomplete") }

        var values: [JSONValue] = []
        var prev = ""
        for (index, line) in lines.enumerated() {
            // 1. Canonical bytes. Name the record's own seq when it is readable.
            guard let value = try? Canonical.parse(line) else {
                // A final record cut short before its newline is an unfinished write, which
                // SPEC §3 calls "incomplete" (Codex review 0602 #5).
                if index == lines.count - 1, !terminated { return .bad("incomplete") }
                return .bad("non-canonical at seq \(index)")
            }
            if Canonical.bytes(of: value) != line {
                return .bad("non-canonical at seq \(value["seq"]?.intValue ?? index)")
            }
            // 2. Schema and seq contiguity.
            guard value["schema"]?.stringValue == Receipt.schema else {
                return .bad("wrong schema at seq \(index)")
            }
            guard let seq = value["seq"]?.intValue else { return .bad("no seq at line \(index)") }
            guard seq == index else { return .bad("seq out of order at line \(index): got \(seq)") }
            // 3. Hash of the record with sha256 blanked.
            guard let sha = value["sha256"]?.stringValue else {
                return .bad("no sha256 at seq \(seq)")
            }
            guard Recorder.seal(value) == sha else { return .bad("hash mismatch at seq \(seq)") }
            // 4. Chain: prev is the previous record's sha256 value.
            guard value["prev"]?.stringValue == prev else {
                return .bad("chain broken at seq \(seq)")
            }
            prev = sha
            values.append(value)
        }

        // 5. Record types: run first, end last, results between. Each record must carry
        // exactly the SPEC §3 fields with their JSON types (Codex review 0602 #1).
        guard values[0]["type"]?.stringValue == "run" else { return .bad("no run header at seq 0") }
        if let found = ReceiptSchema.violation(in: values[0], fields: ReceiptSchema.run) {
            return .bad("\(found) at seq 0")
        }
        guard let header = RunHeader.fromJSON(values[0]) else {
            return .bad("no run header at seq 0")
        }

        guard let last = values.last, last["type"]?.stringValue == "end" else {
            return .bad("incomplete")
        }
        if let found = ReceiptSchema.violation(in: last, fields: ReceiptSchema.end) {
            return .bad("\(found) at seq \(values.count - 1)")
        }
        guard let end = EndRecord.fromJSON(last) else { return .bad("incomplete") }

        // 5a. Every record's runID must equal the header's (Codex review 0602 #2).
        guard end.runID == header.runID else {
            return .bad("runID mismatch at seq \(end.seq)")
        }

        // 5b. Header `expected` entries: caseID non-empty and unique, repeat in 1...20 (SPEC §1).
        var seenCaseIDs: Set<String> = []
        for entry in header.expected {
            guard !entry.caseID.isEmpty,
                  !seenCaseIDs.contains(entry.caseID),
                  (1...20).contains(entry.repeatCount)
            else { return .bad("bad expected entry: \(entry.caseID)") }
            seenCaseIDs.insert(entry.caseID)
        }

        var results: [ResultRecord] = []
        // The check identities (name, arg) of each case's first record, in order.
        var checkSets: [String: [[String]]] = [:]
        for value in values.dropFirst().dropLast() {
            let seq = value["seq"]?.intValue ?? -1
            guard value["type"]?.stringValue == "result" else {
                return .bad("expected result at seq \(seq)")
            }
            if let found = ReceiptSchema.violation(in: value, fields: ReceiptSchema.result) {
                return .bad("\(found) at seq \(seq)")
            }
            guard let record = ResultRecord.fromJSON(value) else {
                return .bad("expected result at seq \(seq)")
            }
            guard record.runID == header.runID else {
                return .bad("runID mismatch at seq \(record.seq)")
            }
            // 5c. Each check identity once per record, and the same checks on every rep of a
            // case, so a rate's denominator is the rep count (Codex review 0602 #7).
            let identities = record.checks.map { [$0.name, $0.arg] }
            var seenChecks: Set<[String]> = []
            for identity in identities where !seenChecks.insert(identity).inserted {
                return .bad("duplicate check \(identity[0]):\(identity[1]) at seq \(record.seq)")
            }
            if let first = checkSets[record.caseID] {
                guard first == identities else {
                    return .bad("check set differs for \(record.caseID) at seq \(record.seq)")
                }
            } else {
                checkSets[record.caseID] = identities
            }
            results.append(record)
        }

        // 6. Trailer count.
        guard end.count == results.count else {
            return .bad("count mismatch: trailer says \(end.count), file has \(results.count)")
        }

        // 7. Expected membership: each (caseID, rep) exactly once. A structured key avoids
        // trapping on `caseID` containing "#" or being empty (Codex review 0602 #3).
        struct ExpectedKey: Hashable { var caseID: String; var rep: Int }
        var wanted: [ExpectedKey: Int] = [:]
        for entry in header.expected {
            for rep in 0..<max(entry.repeatCount, 0) {
                wanted[ExpectedKey(caseID: entry.caseID, rep: rep)] = 0
            }
        }
        for record in results {
            let key = ExpectedKey(caseID: record.caseID, rep: record.rep)
            guard let seen = wanted[key] else {
                return .bad("unexpected result \(record.caseID) rep \(record.rep) at seq \(record.seq)")
            }
            if seen > 0 {
                return .bad("duplicate result \(record.caseID) rep \(record.rep) at seq \(record.seq)")
            }
            wanted[key] = seen + 1
        }
        if let missing = wanted.filter({ $0.value == 0 }).keys.sorted(by: {
            $0.caseID == $1.caseID ? $0.rep < $1.rep : $0.caseID < $1.caseID
        }).first {
            return .bad("missing result for \(missing.caseID) rep \(missing.rep)")
        }

        return .good(results.count)
    }

    private static func bytes(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RecorderError.io(String(describing: error))
        }
    }

    /// The non-empty lines, as raw bytes, and whether the last byte is a newline. The
    /// newline is not part of a line.
    private static func lines(in data: Data) -> (lines: [Data], terminated: Bool) {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
            .filter { !$0.isEmpty }
        return (lines, data.last == 0x0A)
    }
}
