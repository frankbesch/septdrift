// SPEC §3 — the strict shape of a `receipt/0.2` record: exact field sets, JSON types and
// explicit nulls (Codex review 0602 #1). `verify` applies it; `fromJSON` stays lenient.
import Foundation

enum ReceiptSchema {

    indirect enum Kind: Sendable {
        case string
        case int
        case bool
        case stringOrNull
        case intOrNull
        /// null, or the raw value of an `ErrorKind`.
        case errorKind
        case strings
        case object([(String, Kind)])
        case objects([(String, Kind)])
    }

    private static let common: [(String, Kind)] = [
        ("schema", .string), ("type", .string), ("runID", .string), ("seq", .int),
        ("ts", .string), ("prev", .string), ("sha256", .string),
    ]

    static let run: [(String, Kind)] = common + [
        ("host", .object([
            ("os", .string), ("osBuild", .string), ("chip", .string), ("name", .string),
        ])),
        ("backend", .string),
        ("casesSHA256", .string),
        ("expected", .objects([("caseID", .string), ("repeat", .int)])),
    ]

    static let result: [(String, Kind)] = common + [
        ("caseID", .string),
        ("rep", .int),
        ("requestSHA256", .string),
        ("content", .string),
        ("error", .errorKind),
        ("errorDetail", .stringOrNull),
        ("wallMs", .int),
        ("tokens", .object([
            ("in", .intOrNull), ("cached", .intOrNull), ("out", .intOrNull),
            ("reasoning", .intOrNull),
        ])),
        ("assetIDs", .strings),
        ("checks", .objects([
            ("name", .string), ("arg", .string), ("pass", .bool), ("reason", .stringOrNull),
        ])),
    ]

    static let end: [(String, Kind)] = common + [("count", .int)]

    /// The first violation, as `missing field x`, `unknown field x` or `bad field x`
    /// (nested fields as `tokens.in`, `checks[0].pass`); nil when the record conforms.
    static func violation(in record: JSONValue, fields: [(String, Kind)]) -> String? {
        violation(in: record, fields: fields, path: "")
    }

    private static func violation(
        in value: JSONValue, fields: [(String, Kind)], path: String
    ) -> String? {
        guard let members = value.objectMembers else {
            return "bad field \(path.isEmpty ? "record" : String(path.dropLast()))"
        }
        for (name, kind) in fields {
            guard let member = value[name] else { return "missing field \(path)\(name)" }
            if let found = violation(in: member, kind: kind, path: path + name) { return found }
        }
        let known = Set(fields.map { $0.0 })
        if let extra = members.map(\.key).sorted().first(where: { !known.contains($0) }) {
            return "unknown field \(path)\(extra)"
        }
        if Set(members.map(\.key)).count != members.count {
            return "duplicate field in \(path.isEmpty ? "record" : String(path.dropLast()))"
        }
        return nil
    }

    private static func violation(in value: JSONValue, kind: Kind, path: String) -> String? {
        let bad = "bad field \(path)"
        switch kind {
        case .string:
            if case .string = value { return nil }
            return bad
        case .int:
            if case .int = value { return nil }
            return bad
        case .bool:
            if case .bool = value { return nil }
            return bad
        case .stringOrNull:
            if value.isNull { return nil }
            return violation(in: value, kind: .string, path: path)
        case .intOrNull:
            if value.isNull { return nil }
            return violation(in: value, kind: .int, path: path)
        case .errorKind:
            if value.isNull { return nil }
            guard let raw = value.stringValue, ErrorKind(rawValue: raw) != nil else { return bad }
            return nil
        case .strings:
            guard let items = value.arrayValue else { return bad }
            for (index, item) in items.enumerated() {
                guard case .string = item else { return "\(bad)[\(index)]" }
            }
            return nil
        case .object(let fields):
            return violation(in: value, fields: fields, path: path + ".")
        case .objects(let fields):
            guard let items = value.arrayValue else { return bad }
            for (index, item) in items.enumerated() {
                if let found = violation(in: item, fields: fields, path: "\(path)[\(index)].") {
                    return found
                }
            }
            return nil
        }
    }
}
