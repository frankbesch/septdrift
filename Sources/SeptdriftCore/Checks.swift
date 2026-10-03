import Foundation

/// The verdict of one check against one result (SPEC §4).
public struct Outcome: Sendable, Equatable {
    public let pass: Bool
    /// Short lowercase reason, present only on failure.
    public let reason: String?

    public init(pass: Bool, reason: String? = nil) {
        self.pass = pass
        self.reason = reason
    }

    static let ok = Outcome(pass: true, reason: nil)
    static func fail(_ reason: String) -> Outcome { Outcome(pass: false, reason: reason) }
}

/// Pure check evaluation: `(Check, Case, Result) -> Outcome`. No I/O, no state.
/// The case is needed because `json_field_equals` is typed by the schema kind (SPEC §4.5).
public enum Checks {

    public static func evaluate(_ check: Check, in aCase: Case, on result: Result) -> Outcome {
        // SPEC §4.1 — expect_error is judged first, and only on the error field.
        if case .expectError(let wanted) = check {
            guard let actual = result.error else { return .fail("no error") }
            if let wanted, wanted != actual { return .fail("wrong error: \(actual.rawValue)") }
            return .ok
        }

        // SPEC §4.2 — any other check on a result carrying an error fails.
        if result.error != nil { return .fail("error") }

        switch check {
        case .expectError:
            return .ok   // handled above; unreachable.

        case .contains(let needle):
            // Case-sensitive substring of content.
            return result.content.contains(needle) ? .ok : .fail("not found")

        case .notContains(let needle):
            return result.content.contains(needle) ? .fail("found") : .ok

        case .regex(let pattern):
            // Unanchored NSRegularExpression. SPEC §4.4 makes an invalid pattern a load-time
            // validation error (exit 3); the evaluator still degrades to a failed check.
            guard let re = try? NSRegularExpression(pattern: pattern) else {
                return .fail("invalid regex")
            }
            let range = NSRange(result.content.startIndex..., in: result.content)
            let hit = re.firstMatch(in: result.content, range: range) != nil
            return hit ? .ok : .fail("no match")

        case .jsonFieldEquals(let field, let value):
            // Validation guarantees the field is declared; fall back to string comparison
            // if it is not (unreachable after CaseLoader).
            let kind = aCase.kind(of: field) ?? .string
            return jsonFieldEquals(field: field, value: value, kind: kind, content: result.content)

        case .jsonFieldIn(let field, let values):
            let kind = aCase.kind(of: field) ?? .string
            return jsonField(field, in: result.content) { raw in
                if values.contains(where: { matches(raw, $0, kind: kind) }) { return .ok }
                return .fail("expected one of \(values.joined(separator: ", ")) got \(render(raw))")
            }

        case .jsonFieldRange(let field, let min, let max):
            let kind = aCase.kind(of: field) ?? .double
            return jsonField(field, in: result.content) { raw in
                guard let number = raw as? NSNumber, !isBoolean(raw) else {
                    return .fail("not a number: \(render(raw))")
                }
                let value = number.doubleValue
                if kind == .int, exactInt(raw) == nil {
                    return .fail("not an integer: \(render(raw))")
                }
                if let min, value < min { return .fail("\(render(raw)) < \(bound(min))") }
                if let max, value > max { return .fail("\(render(raw)) > \(bound(max))") }
                return .ok
            }

        case .jsonFieldRank(let field, let ladder, let min, let max):
            return jsonField(field, in: result.content) { raw in
                guard let rung = raw as? String, let rank = ladder.firstIndex(of: rung) else {
                    return .fail("off ladder: \(render(raw))")
                }
                if let min, let floor = ladder.firstIndex(of: min), rank < floor {
                    return .fail("\(rung) < \(min)")
                }
                if let max, let ceiling = ladder.firstIndex(of: max), rank > ceiling {
                    return .fail("\(rung) > \(max)")
                }
                return .ok
            }

        case .maxWallMs(let limit):
            return result.wallMs <= limit ? .ok : .fail("\(result.wallMs) > \(limit)")

        case .maxOutputTokens(let limit):
            guard let out = result.tokensOut else { return .fail("unreported") }
            return out <= limit ? .ok : .fail("\(out) > \(limit)")
        }
    }

    /// Every declared check of the case, in file order.
    public static func evaluateAll(_ aCase: Case, on result: Result) -> [Outcome] {
        aCase.checks.map { evaluate($0, in: aCase, on: result) }
    }

    // MARK: - json_field_equals

    /// Parse `content` as a JSON object and compare one field, typed by its schema kind.
    ///   - string: exact string equality against the rendered value.
    ///   - int:    integer equality (both sides must be integers).
    ///   - double: equality after `Double(value)`.
    ///   - bool:   the literals `true` / `false`.
    /// The failure reason is always "expected X got Y", with Y rendered as booleans
    /// `true`/`false`, null as `null`, numbers via `String(describing:)` (1.0 -> "1").
    private static func jsonFieldEquals(
        field: String, value: String, kind: Case.FieldKind, content: String
    ) -> Outcome {
        jsonField(field, in: content) { raw in
            matches(raw, value, kind: kind) ? .ok : .fail("expected \(value) got \(render(raw))")
        }
    }

    /// Parse `content` as a JSON object and judge one field of it.
    private static func jsonField(
        _ field: String, in content: String, judge: (Any) -> Outcome
    ) -> Outcome {
        guard let data = content.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let object = any as? [String: Any]
        else {
            return .fail("not json object")
        }
        guard let raw = object[field] else { return .fail("missing") }
        return judge(raw)
    }

    private static func matches(_ raw: Any, _ value: String, kind: Case.FieldKind) -> Bool {
        switch kind {
        case .string:
            return !isBoolean(raw) && (raw is String) && render(raw) == value
        case .int:
            guard let wanted = Int(value), let actual = exactInt(raw) else { return false }
            return actual == wanted
        case .double:
            guard let number = raw as? NSNumber, !isBoolean(raw), let wanted = Double(value) else {
                return false
            }
            return number.doubleValue == wanted
        case .bool:
            guard isBoolean(raw), value == "true" || value == "false" else { return false }
            return render(raw) == value
        }
    }

    /// The exact integer a JSON number holds, or nil. An integer literal is read exactly; a
    /// floating literal counts only when it is integral and below 2^53, where a Double is
    /// still exact (Codex review 0602 #14).
    private static func exactInt(_ raw: Any) -> Int? {
        guard let number = raw as? NSNumber, !isBoolean(raw) else { return nil }
        if !CFNumberIsFloatType(number) { return Int(exactly: number) }
        let d = number.doubleValue
        guard d.isFinite, d == d.rounded(), d.magnitude < 9.007199254740992e15 else { return nil }
        return Int(d)
    }

    /// A bound in a failure reason: integral values without a decimal point.
    private static func bound(_ value: Double) -> String {
        Canonical.string(of: Check.number(value))
    }

    private static func isBoolean(_ raw: Any) -> Bool {
        guard let number = raw as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func render(_ raw: Any) -> String {
        if isBoolean(raw) {
            return (raw as! NSNumber).boolValue ? "true" : "false"
        }
        if raw is NSNull { return "null" }
        if let string = raw as? String { return string }
        return String(describing: raw)
    }
}
