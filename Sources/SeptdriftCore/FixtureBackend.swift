// SPEC §2 — the deterministic CI backend. A JSONL file keyed by (caseID, rep).
import Foundation

/// A fixture file that cannot be used as declared. The CLI maps every case to exit 3.
public enum FixtureError: Error, Equatable, CustomStringConvertible {
    case unreadable(file: String, reason: String)
    case malformedLine(file: String, line: Int, reason: String)
    case duplicateKey(caseID: String, rep: Int, line: Int)
    case invalidErrorKind(file: String, line: Int, value: String)
    case missingField(file: String, line: Int, field: String)
    case negativeValue(file: String, line: Int, field: String)

    public var description: String {
        switch self {
        case .unreadable(let f, let r):
            return "\(f): cannot read the fixture file: \(r)"
        case .malformedLine(let f, let l, let r):
            return "\(f): line \(l): \(r)"
        case .duplicateKey(let id, let rep, let line):
            return "duplicate fixture key (\(id), rep \(rep)) at line \(line)"
        case .invalidErrorKind(let f, let l, let v):
            return "\(f): line \(l): unknown error kind '\(v)'"
        case .missingField(let f, let l, let field):
            return "\(f): line \(l): missing required field '\(field)'"
        case .negativeValue(let f, let l, let field):
            return "\(f): line \(l): field '\(field)' must not be negative"
        }
    }
}

/// Replays recorded answers. No model, no clock, no randomness (SPEC §2).
public struct FixtureBackend: Backend {

    public var name: String { "fixture" }

    /// Key is "<caseID>\u{0}<rep>"; rep is 0-based.
    private let records: [String: Result]

    /// The record as written in the fixture file. Optional token fields stay nil when absent.
    private struct Line: Decodable {
        var caseID: String
        var rep: Int
        var content: String?
        var wallMs: Int?
        var tokensIn: Int?
        var tokensCached: Int?
        var tokensOut: Int?
        var tokensReasoning: Int?
        var assetIDs: [String]?
        var error: String?
        var errorDetail: String?
    }

    private static func key(_ caseID: String, _ rep: Int) -> String {
        "\(caseID)\u{0}\(rep)"
    }

    private static func requireNonNegative(
        _ value: Int, field: String, file: String, line: Int
    ) throws {
        if value < 0 {
            throw FixtureError.negativeValue(file: file, line: line, field: field)
        }
    }

    private static func requireNonNegative(
        _ value: Int?, field: String, file: String, line: Int
    ) throws {
        guard let value else { return }
        try requireNonNegative(value, field: field, file: file, line: line)
    }

    public init(fileURL: URL) throws {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw FixtureError.unreadable(file: fileURL.path, reason: error.localizedDescription)
        }

        let decoder = JSONDecoder()
        var built: [String: Result] = [:]
        var seenAt: [String: Int] = [:]

        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let line: Line
            do {
                line = try decoder.decode(Line.self, from: Data(trimmed.utf8))
            } catch {
                throw FixtureError.malformedLine(
                    file: fileURL.path, line: lineNumber, reason: "\(error)")
            }

            var kind: ErrorKind?
            if let raw = line.error {
                guard let parsed = ErrorKind(rawValue: raw) else {
                    throw FixtureError.invalidErrorKind(
                        file: fileURL.path, line: lineNumber, value: raw)
                }
                kind = parsed
            }

            let key = Self.key(line.caseID, line.rep)
            if seenAt[key] != nil {
                throw FixtureError.duplicateKey(
                    caseID: line.caseID, rep: line.rep, line: lineNumber)
            }
            seenAt[key] = lineNumber

            if kind == nil && line.content == nil {
                throw FixtureError.missingField(
                    file: fileURL.path, line: lineNumber, field: "content")
            }
            guard let wallMs = line.wallMs else {
                throw FixtureError.missingField(
                    file: fileURL.path, line: lineNumber, field: "wallMs")
            }
            try Self.requireNonNegative(wallMs, field: "wallMs", file: fileURL.path, line: lineNumber)
            try Self.requireNonNegative(line.tokensIn, field: "tokensIn", file: fileURL.path, line: lineNumber)
            try Self.requireNonNegative(line.tokensCached, field: "tokensCached", file: fileURL.path, line: lineNumber)
            try Self.requireNonNegative(line.tokensOut, field: "tokensOut", file: fileURL.path, line: lineNumber)
            try Self.requireNonNegative(
                line.tokensReasoning, field: "tokensReasoning", file: fileURL.path, line: lineNumber)

            built[key] = Result(
                content: kind == nil ? (line.content ?? "") : "",
                wallMs: wallMs,
                tokensIn: line.tokensIn,
                tokensCached: line.tokensCached,
                tokensOut: line.tokensOut,
                tokensReasoning: line.tokensReasoning,
                assetIDs: line.assetIDs ?? [],
                error: kind,
                errorDetail: line.errorDetail
            )
        }

        records = built
    }

    public func respond(to aCase: Case, rep: Int) async throws -> Result {
        records[Self.key(aCase.id, rep)]
            ?? Result(content: "", wallMs: 0, error: .other, errorDetail: "no fixture")
    }
}
