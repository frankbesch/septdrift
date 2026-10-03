// SPEC §1 — the declared case file, in memory.
import Foundation

/// Typed backend error (SPEC §2). Declared here because `Check.expectError` names it.
public enum ErrorKind: String, Sendable, Codable, CaseIterable, Hashable {
    case guardrail
    case refusal
    case unsupported
    case context
    case unavailable
    case other
}

/// One field of a `format: json` schema. The list order is part of the request (SPEC §1).
public struct SchemaField: Sendable, Equatable, Hashable {
    public var name: String
    public var kind: Case.FieldKind
    public var description: String?
    public var optional: Bool

    public init(
        name: String,
        kind: Case.FieldKind,
        description: String? = nil,
        optional: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.optional = optional
    }
}

/// `GenerationOptions` as declared in the case file (SPEC §1). An absent value means
/// "framework default"; the recorder writes "default" for it.
public struct GenerationOptionsSpec: Sendable, Equatable, Hashable {
    public var temperature: Double?
    public var maxResponseTokens: Int?

    public init(temperature: Double? = nil, maxResponseTokens: Int? = nil) {
        self.temperature = temperature
        self.maxResponseTokens = maxResponseTokens
    }
}

/// One declared case: a prompt, an output shape, and the checks it must satisfy.
public struct Case: Sendable, Equatable {

    /// Output shape requested from the backend.
    public enum Format: String, Sendable, Equatable {
        case text
        case json
    }

    /// Field type in a flat `format: json` schema.
    public enum FieldKind: String, Sendable, Equatable, Hashable {
        case string
        case int
        case double
        case bool
    }

    public var id: String
    public var instructions: String?
    public var context: String?
    public var prompt: String
    public var format: Format
    /// Ordered; nil unless `format: json`.
    public var schema: [SchemaField]?
    public var options: GenerationOptionsSpec?
    public var `repeat`: Int
    public var checks: [Check]

    public init(
        id: String,
        instructions: String? = nil,
        context: String? = nil,
        prompt: String,
        format: Format = .text,
        schema: [SchemaField]? = nil,
        options: GenerationOptionsSpec? = nil,
        repeat repeatCount: Int = 1,
        checks: [Check]
    ) {
        self.id = id
        self.instructions = instructions
        self.context = context
        self.prompt = prompt
        self.format = format
        self.schema = schema
        self.options = options
        self.repeat = repeatCount
        self.checks = checks
    }

    /// The declared kind of one schema field, or nil when the field is not declared.
    public func kind(of field: String) -> FieldKind? {
        schema?.first { $0.name == field }?.kind
    }
}

/// One declared check. `name` and `arg` are the receipt `checks[]` fields (SPEC §3),
/// and together they are the check identity used by `diff` (SPEC §5).
public enum Check: Sendable, Equatable, Hashable {
    case contains(String)
    case notContains(String)
    case regex(String)
    case jsonFieldEquals(field: String, value: String)
    /// Label set: the field equals one of `values`, each typed by the schema kind.
    case jsonFieldIn(field: String, values: [String])
    /// Inclusive numeric bounds on an int or double field; nil is an open end.
    case jsonFieldRange(field: String, min: Double?, max: Double?)
    /// Inclusive rung bounds on a string field. `ladder` is ordered lowest to highest;
    /// a value that is not a rung fails, so a fail-closed value never passes a threshold.
    case jsonFieldRank(field: String, ladder: [String], min: String?, max: String?)
    case maxWallMs(Int)
    case maxOutputTokens(Int)
    /// `expect_error`. The payload is the demanded kind; **nil means `any` non-nil error**
    /// (the chosen representation for SPEC §1's `any`; there is no separate `ExpectedError` type).
    case expectError(ErrorKind?)

    /// The check key as written in the case file.
    public var name: String {
        switch self {
        case .contains: return "contains"
        case .notContains: return "not_contains"
        case .regex: return "regex"
        case .jsonFieldEquals: return "json_field_equals"
        case .jsonFieldIn: return "json_field_in"
        case .jsonFieldRange: return "json_field_range"
        case .jsonFieldRank: return "json_field_rank"
        case .maxWallMs: return "max_wall_ms"
        case .maxOutputTokens: return "max_output_tokens"
        case .expectError: return "expect_error"
        }
    }

    /// The check argument, rendered as one string for the receipt.
    public var arg: String {
        switch self {
        case .contains(let s): return s
        case .notContains(let s): return s
        case .regex(let s): return s
        case .jsonFieldEquals(let field, let value): return "\(field)=\(value)"
        // Canonical JSON after the field name: a schema field name cannot contain "=",
        // so the rendering is unambiguous (Codex review 0602 #6).
        case .jsonFieldIn(let field, let values):
            return "\(field)=" + Canonical.string(of: .array(values.map { .string($0) }))
        case .jsonFieldRange(let field, let min, let max):
            return "\(field)=" + Canonical.string(of: .array([Check.number(min), Check.number(max)]))
        case .jsonFieldRank(let field, let ladder, let min, let max):
            return "\(field)=" + Canonical.string(of: .obj([
                ("ladder", .array(ladder.map { .string($0) })),
                ("min", .stringOrNull(min)),
                ("max", .stringOrNull(max)),
            ]))
        case .maxWallMs(let n): return String(n)
        case .maxOutputTokens(let n): return String(n)
        case .expectError(let kind): return kind?.rawValue ?? "any"
        }
    }

    /// A bound as JSON: null when open, an integer where integral.
    static func number(_ value: Double?) -> JSONValue {
        guard let value else { return .null }
        if value == value.rounded(), value.magnitude < 9.007199254740992e15 {
            return .int(Int(value))
        }
        return .double(value)
    }
}
