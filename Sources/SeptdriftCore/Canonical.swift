// SPEC §3 — canonical bytes. The only thing that is ever hashed.
//
// Rules (SPEC §3): JSON object, keys sorted by UTF-8 byte order, UTF-8 encoding, no
// whitespace, `/` unescaped, numbers rendered as integers where integral, `null` for
// absent optionals, no unknown fields. The serializer below is hand written on purpose:
// `JSONSerialization` gives no ordering, spacing or escaping guarantees, so it may not
// produce the hashed bytes. It is used for *parsing* only.
import Foundation
import CryptoKit

/// A JSON value in the canonical model. `object` keeps its members in an array so the
/// declared order of a schema survives a round trip; the serializer sorts keys itself.
public enum JSONValue: Sendable, Equatable {

    /// One `key: value` member of an object.
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    /// Convenience: build an object from an ordered list of pairs.
    public static func obj(_ pairs: [(String, JSONValue)]) -> JSONValue {
        .object(pairs.map { Member($0.0, $0.1) })
    }

    /// `null` when the optional is absent (SPEC §3).
    public static func stringOrNull(_ value: String?) -> JSONValue {
        value.map { JSONValue.string($0) } ?? .null
    }

    public static func intOrNull(_ value: Int?) -> JSONValue {
        value.map { JSONValue.int($0) } ?? .null
    }

    public static func doubleOrNull(_ value: Double?) -> JSONValue {
        value.map { JSONValue.double($0) } ?? .null
    }

    // MARK: - Readers (used by `verify` and `read`)

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var objectMembers: [Member]? {
        guard case .object(let members) = self else { return nil }
        return members
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let items) = self else { return nil }
        return items
    }

    public var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    public var intValue: Int? {
        switch self {
        case .int(let n): return n
        case .double(let d) where d == d.rounded() && d.magnitude < 9.007199254740992e15:
            return Int(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let n): return Double(n)
        case .double(let d): return d
        default: return nil
        }
    }

    public var boolValue: Bool? {
        guard case .bool(let b) = self else { return nil }
        return b
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Same value with one member replaced (or appended). Used to blank `sha256` before hashing.
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(Member(key, value))
        }
        return .object(members)
    }
}

public enum CanonicalError: Error, Equatable {
    case notJSON
    case unsupportedValue
}

public enum Canonical {

    // MARK: - Serialize

    /// The canonical UTF-8 bytes of a value. Never throws: every `JSONValue` is renderable.
    public static func bytes(of value: JSONValue) -> Data {
        var out = String()
        write(value, into: &out)
        return Data(out.utf8)
    }

    /// Canonical bytes as a string (tests and diagnostics).
    public static func string(of value: JSONValue) -> String {
        var out = String()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String) {
        switch value {
        case .object(let members):
            // Keys sorted by UTF-8 byte order, not by Swift's collation.
            let sorted = members.sorted { lhs, rhs in
                Array(lhs.key.utf8).lexicographicallyPrecedes(Array(rhs.key.utf8))
            }
            out += "{"
            for (index, member) in sorted.enumerated() {
                if index > 0 { out += "," }
                writeString(member.key, into: &out)
                out += ":"
                write(member.value, into: &out)
            }
            out += "}"

        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"

        case .string(let s):
            writeString(s, into: &out)

        case .int(let n):
            out += String(n)

        case .double(let d):
            out += number(d)

        case .bool(let b):
            out += b ? "true" : "false"

        case .null:
            out += "null"
        }
    }

    /// Integral doubles below 2^53 render as integers; every other finite double renders as
    /// Swift's shortest round-trip description (SPEC §3). A non-finite value has no JSON
    /// literal and renders as `null`; none can reach here, because `parse` and the case
    /// loader both reject one (Codex review 0602 #4).
    private static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), d.magnitude < 9.007199254740992e15 {
            return String(Int64(d))
        }
        return String(d)
    }

    /// Minimal JSON escaping: `"` and `\`, the five short control escapes, every other
    /// control character as `\u00XX`. `/` is left alone (SPEC §3).
    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // MARK: - Hash

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash of the canonical bytes of a value.
    public static func sha256Hex(of value: JSONValue) -> String {
        sha256Hex(bytes(of: value))
    }

    // MARK: - Parse

    /// Parse one JSON line. `JSONSerialization` is fine here: parsing does not define bytes.
    /// A number that is integral becomes `.int`, so a line carrying `2.0` re-serializes as
    /// `2` and is correctly reported as non-canonical.
    public static func parse(_ line: Data) throws -> JSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
        } catch {
            throw CanonicalError.notJSON
        }
        return try convert(any)
    }

    private static func convert(_ any: Any) throws -> JSONValue {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            // An integer literal is read exactly, never through Double (Codex review 0602 #4).
            if !CFNumberIsFloatType(number) {
                guard let exact = Int(exactly: number) else { throw CanonicalError.unsupportedValue }
                return .int(exact)
            }
            let d = number.doubleValue
            guard d.isFinite else { throw CanonicalError.unsupportedValue }
            if d == d.rounded(), d.magnitude < 9.007199254740992e15 { return .int(Int(d)) }
            return .double(d)
        }
        if let s = any as? String { return .string(s) }
        if let list = any as? [Any] { return .array(try list.map(convert)) }
        if let dict = any as? [String: Any] {
            // Order does not matter: `bytes(of:)` sorts keys.
            return .object(try dict.map { JSONValue.Member($0.key, try convert($0.value)) })
        }
        throw CanonicalError.unsupportedValue
    }

    /// True when the line's bytes are exactly the canonical bytes of what it parses to.
    public static func isCanonical(_ line: Data) -> Bool {
        guard let value = try? parse(line) else { return false }
        return bytes(of: value) == line
    }
}
