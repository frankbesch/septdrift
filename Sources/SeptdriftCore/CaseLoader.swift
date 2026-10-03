// SPEC §1 — load and validate case files. No model call happens until this passes.
import Foundation
import Yams

/// Every way a case file can fail validation. Exit 3 at the CLI (SPEC §1).
public enum CaseError: Error, Equatable, CustomStringConvertible {
    case unreadable(file: String, reason: String)
    case malformedFile(file: String, reason: String)
    case notAList(file: String)
    case notAMapping(file: String, index: Int)
    case missingID(file: String, index: Int)
    case invalidID(file: String, id: String)
    case duplicateID(file: String, id: String, firstFile: String)
    case missingPrompt(file: String, id: String)
    case missingChecks(file: String, id: String)
    case emptyChecks(file: String, id: String)
    case invalidFormat(file: String, id: String, value: String)
    case invalidFieldKind(file: String, id: String, field: String, value: String)
    case duplicateSchemaField(file: String, id: String, field: String)
    case schemaWithoutJSONFormat(file: String, id: String)
    case jsonFormatWithoutSchema(file: String, id: String)
    case repeatOutOfRange(file: String, id: String, value: String)
    case unknownCheck(file: String, id: String, key: String)
    case malformedCheck(file: String, id: String, reason: String)
    case invalidRegex(file: String, id: String, pattern: String, reason: String)
    case jsonFieldEqualsWithTextFormat(file: String, id: String)
    case unknownSchemaField(file: String, id: String, field: String)
    case invalidErrorKind(file: String, id: String, value: String)
    case expectErrorWithOtherChecks(file: String, id: String)
    case invalidValue(file: String, id: String, field: String)
    case invalidSchemaFieldName(file: String, id: String, field: String)

    public var description: String {
        switch self {
        case .unreadable(let f, let r):
            return "\(f): cannot read the case file: \(r)"
        case .malformedFile(let f, let r):
            return "\(f): cannot parse the case file: \(r)"
        case .notAList(let f):
            return "\(f): the case file must be a list of cases"
        case .notAMapping(let f, let i):
            return "\(f): case at index \(i) is not a mapping"
        case .missingID(let f, let i):
            return "\(f): case at index \(i) has no id"
        case .invalidID(let f, let id):
            return "\(f): id '\(id)' must match [a-z0-9-]+"
        case .duplicateID(let f, let id, let first):
            return "\(f): id '\(id)' is a duplicate, already declared in \(first)"
        case .missingPrompt(let f, let id):
            return "\(f): id '\(id)' has no prompt"
        case .missingChecks(let f, let id):
            return "\(f): id '\(id)' has no checks"
        case .emptyChecks(let f, let id):
            return "\(f): id '\(id)' has an empty checks list, at least one check is required"
        case .invalidFormat(let f, let id, let v):
            return "\(f): id '\(id)' has format '\(v)', expected text or json"
        case .invalidFieldKind(let f, let id, let field, let v):
            return "\(f): id '\(id)' schema field '\(field)' has kind '\(v)', expected string, int, double or bool"
        case .duplicateSchemaField(let f, let id, let field):
            return "\(f): id '\(id)' declares the schema field '\(field)' twice"
        case .schemaWithoutJSONFormat(let f, let id):
            return "\(f): id '\(id)' declares a schema without format json"
        case .jsonFormatWithoutSchema(let f, let id):
            return "\(f): id '\(id)' declares format json without a schema"
        case .repeatOutOfRange(let f, let id, let v):
            return "\(f): id '\(id)' has repeat '\(v)', expected an integer in 1...20"
        case .unknownCheck(let f, let id, let key):
            return "\(f): id '\(id)' has an unknown check '\(key)'"
        case .malformedCheck(let f, let id, let r):
            return "\(f): id '\(id)' has a malformed check: \(r)"
        case .invalidRegex(let f, let id, let p, let r):
            return "\(f): id '\(id)' has an invalid regex '\(p)': \(r)"
        case .jsonFieldEqualsWithTextFormat(let f, let id):
            return "\(f): id '\(id)' uses json_field_equals with format text, it needs format json"
        case .unknownSchemaField(let f, let id, let field):
            return "\(f): id '\(id)' uses json_field_equals on '\(field)', which the schema does not declare"
        case .invalidErrorKind(let f, let id, let v):
            return "\(f): id '\(id)' has expect_error '\(v)', expected guardrail, refusal, unsupported, context, unavailable or any"
        case .expectErrorWithOtherChecks(let f, let id):
            return "\(f): id '\(id)' combines expect_error with another check, expect_error must be the only check"
        case .invalidValue(let f, let id, let field):
            return "\(f): id '\(id)' has an invalid value for '\(field)'"
        case .invalidSchemaFieldName(let f, let id, let field):
            return "\(f): id '\(id)' schema field '\(field)' is not an identifier"
        }
    }
}

/// Reads cases from one file or a directory of files, and validates them (SPEC §1).
public enum CaseLoader {

    private static let idPattern = try! NSRegularExpression(pattern: "^[a-z0-9-]+$")
    private static let schemaFieldNamePattern = try! NSRegularExpression(
        pattern: "^[A-Za-z_][A-Za-z0-9_]*$")

    /// Load every case at `path`. `path` is a `.yaml`/`.yml`/`.json` file, or a directory
    /// of them, read in filename order. Throws `CaseError` on the first validation failure.
    public static func load(path: String) throws -> [Case] {
        let files = try files(at: path)
        var cases: [Case] = []
        var seen: [String: String] = [:]   // id -> file that first declared it
        for file in files {
            for aCase in try loadFile(file) {
                if let first = seen[aCase.id] {
                    throw CaseError.duplicateID(file: file, id: aCase.id, firstFile: first)
                }
                seen[aCase.id] = file
                cases.append(aCase)
            }
        }
        return cases
    }

    // MARK: file discovery

    private static func files(at path: String) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw CaseError.unreadable(file: path, reason: "no such file or directory")
        }
        if !isDir.boolValue { return [path] }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: path)
        } catch {
            throw CaseError.unreadable(file: path, reason: error.localizedDescription)
        }
        let exts: Set<String> = ["yaml", "yml", "json"]
        return names
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { (path as NSString).appendingPathComponent($0) }
    }

    // MARK: one file

    private static func loadFile(_ file: String) throws -> [Case] {
        let text: String
        do {
            text = try String(contentsOfFile: file, encoding: .utf8)
        } catch {
            throw CaseError.unreadable(file: file, reason: error.localizedDescription)
        }
        let ext = (file as NSString).pathExtension.lowercased()
        let parsed: Any?
        if ext == "json" {
            guard let data = text.data(using: .utf8) else {
                throw CaseError.malformedFile(file: file, reason: "not valid UTF-8")
            }
            do {
                parsed = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw CaseError.malformedFile(file: file, reason: error.localizedDescription)
            }
        } else {
            do {
                parsed = try Yams.load(yaml: text)
            } catch {
                throw CaseError.malformedFile(file: file, reason: "\(error)")
            }
        }
        guard let list = parsed as? [Any] else {
            throw CaseError.notAList(file: file)
        }
        return try list.enumerated().map { try makeCase(from: $0.element, index: $0.offset, file: file) }
    }

    // MARK: one case

    private static func makeCase(from raw: Any, index: Int, file: String) throws -> Case {
        guard let map = raw as? [String: Any] else {
            throw CaseError.notAMapping(file: file, index: index)
        }

        guard let id = string(map["id"]), !id.isEmpty else {
            throw CaseError.missingID(file: file, index: index)
        }
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        guard idPattern.firstMatch(in: id, range: range) != nil else {
            throw CaseError.invalidID(file: file, id: id)
        }

        guard let prompt = string(map["prompt"]), !prompt.isEmpty else {
            throw CaseError.missingPrompt(file: file, id: id)
        }

        // format
        var format = Case.Format.text
        if let rawFormat = map["format"], !(rawFormat is NSNull) {
            guard let name = string(rawFormat), let parsed = Case.Format(rawValue: name) else {
                throw CaseError.invalidFormat(file: file, id: id, value: describe(map["format"]))
            }
            format = parsed
        }

        // schema — an ORDERED list of fields (SPEC §1)
        var schema: [SchemaField]?
        if let rawSchema = map["schema"], !(rawSchema is NSNull) {
            guard let fields = rawSchema as? [Any] else {
                throw CaseError.invalidValue(file: file, id: id, field: "schema")
            }
            var built: [SchemaField] = []
            var seenNames: Set<String> = []
            for entry in fields {
                guard let fieldMap = entry as? [String: Any],
                      let name = string(fieldMap["name"]), !name.isEmpty
                else {
                    throw CaseError.invalidValue(file: file, id: id, field: "schema")
                }
                let nameRange = NSRange(name.startIndex..<name.endIndex, in: name)
                guard schemaFieldNamePattern.firstMatch(in: name, range: nameRange) != nil else {
                    throw CaseError.invalidSchemaFieldName(file: file, id: id, field: name)
                }
                guard let kindName = string(fieldMap["kind"]),
                      let kind = Case.FieldKind(rawValue: kindName)
                else {
                    throw CaseError.invalidFieldKind(
                        file: file, id: id, field: name, value: describe(fieldMap["kind"]))
                }
                guard seenNames.insert(name).inserted else {
                    throw CaseError.duplicateSchemaField(file: file, id: id, field: name)
                }
                var optional = false
                if let rawOptional = fieldMap["optional"], !(rawOptional is NSNull) {
                    guard let flag = bool(rawOptional) else {
                        throw CaseError.invalidValue(file: file, id: id, field: "schema.optional")
                    }
                    optional = flag
                }
                built.append(SchemaField(
                    name: name,
                    kind: kind,
                    description: string(fieldMap["description"]),
                    optional: optional
                ))
            }
            schema = built
        }
        if schema != nil && format != .json {
            throw CaseError.schemaWithoutJSONFormat(file: file, id: id)
        }
        if format == .json && schema == nil {
            throw CaseError.jsonFormatWithoutSchema(file: file, id: id)
        }

        // options
        var options: GenerationOptionsSpec?
        if let rawOptions = map["options"], !(rawOptions is NSNull) {
            guard let optionMap = rawOptions as? [String: Any] else {
                throw CaseError.invalidValue(file: file, id: id, field: "options")
            }
            var temperature: Double?
            if let rawTemp = optionMap["temperature"], !(rawTemp is NSNull) {
                guard let t = double(rawTemp), t.isFinite else {
                    throw CaseError.invalidValue(file: file, id: id, field: "options.temperature")
                }
                temperature = t
            }
            var maxResponseTokens: Int?
            if let rawMax = optionMap["max_response_tokens"], !(rawMax is NSNull) {
                guard let n = int(rawMax) else {
                    throw CaseError.invalidValue(
                        file: file, id: id, field: "options.max_response_tokens")
                }
                maxResponseTokens = n
            }
            options = GenerationOptionsSpec(
                temperature: temperature, maxResponseTokens: maxResponseTokens)
        }

        // repeat
        var repeatCount = 1
        if let rawRepeat = map["repeat"], !(rawRepeat is NSNull) {
            guard let n = int(rawRepeat) else {
                throw CaseError.repeatOutOfRange(file: file, id: id, value: describe(rawRepeat))
            }
            guard (1...20).contains(n) else {
                throw CaseError.repeatOutOfRange(file: file, id: id, value: String(n))
            }
            repeatCount = n
        }

        // checks
        guard let rawChecks = map["checks"], !(rawChecks is NSNull) else {
            throw CaseError.missingChecks(file: file, id: id)
        }
        guard let checkList = rawChecks as? [Any] else {
            throw CaseError.malformedCheck(file: file, id: id, reason: "checks must be a list")
        }
        guard !checkList.isEmpty else {
            throw CaseError.emptyChecks(file: file, id: id)
        }
        let checks = try checkList.map {
            try makeCheck(from: $0, id: id, file: file, format: format, schema: schema)
        }
        // SPEC §1: expect_error may not share a case with any other check.
        let expectErrorCount = checks.filter { if case .expectError = $0 { return true } else { return false } }.count
        if expectErrorCount > 0 && checks.count > 1 {
            throw CaseError.expectErrorWithOtherChecks(file: file, id: id)
        }

        return Case(
            id: id,
            instructions: string(map["instructions"]),
            context: string(map["context"]),
            prompt: prompt,
            format: format,
            schema: schema,
            options: options,
            repeat: repeatCount,
            checks: checks
        )
    }

    // MARK: one check

    private static func makeCheck(
        from raw: Any, id: String, file: String, format: Case.Format, schema: [SchemaField]?
    ) throws -> Check {
        guard let map = raw as? [String: Any] else {
            throw CaseError.malformedCheck(file: file, id: id, reason: "a check must be a mapping")
        }
        guard map.count == 1, let key = map.keys.first else {
            throw CaseError.malformedCheck(
                file: file, id: id, reason: "a check must have exactly one key, found \(map.count)")
        }
        let value = map[key] as Any

        func stringArg() throws -> String {
            guard let s = string(value) else {
                throw CaseError.malformedCheck(
                    file: file, id: id, reason: "\(key) needs a string argument")
            }
            return s
        }
        func intArg() throws -> Int {
            guard let n = int(value) else {
                throw CaseError.malformedCheck(
                    file: file, id: id, reason: "\(key) needs an integer argument")
            }
            return n
        }

        switch key {
        case "contains":
            return .contains(try stringArg())
        case "not_contains":
            return .notContains(try stringArg())
        case "regex":
            let pattern = try stringArg()
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                throw CaseError.invalidRegex(
                    file: file, id: id, pattern: pattern, reason: error.localizedDescription)
            }
            return .regex(pattern)
        case "json_field_equals":
            guard format == .json else {
                throw CaseError.jsonFieldEqualsWithTextFormat(file: file, id: id)
            }
            guard let pair = value as? [String: Any] else {
                throw CaseError.malformedCheck(
                    file: file, id: id, reason: "json_field_equals needs {field, value}")
            }
            // SPEC v0.3.1: the value may be a quoted string or a bare scalar (3, true, 1.5);
            // a bare scalar is stringified ("3", "true", "1.5").
            guard let field = string(pair["field"]), let expected = scalar(pair["value"]) else {
                throw CaseError.malformedCheck(
                    file: file, id: id, reason: "json_field_equals needs {field, value}")
            }
            guard schema?.contains(where: { $0.name == field }) == true else {
                throw CaseError.unknownSchemaField(file: file, id: id, field: field)
            }
            return .jsonFieldEquals(field: field, value: expected)
        case "json_field_in", "json_field_range", "json_field_rank":
            func bad(_ reason: String) -> CaseError {
                .malformedCheck(file: file, id: id, reason: "\(key) \(reason)")
            }
            guard format == .json else { throw bad("needs format: json") }
            guard let pair = value as? [String: Any], let field = string(pair["field"]) else {
                throw bad("needs a mapping with a field")
            }
            guard let kind = schema?.first(where: { $0.name == field })?.kind else {
                throw CaseError.unknownSchemaField(file: file, id: id, field: field)
            }
            func only(_ allowed: Set<String>) throws {
                if let extra = pair.keys.sorted().first(where: { !allowed.contains($0) }) {
                    throw bad("has an unknown key '\(extra)'")
                }
            }
            switch key {
            case "json_field_in":
                try only(["field", "values"])
                guard let list = pair["values"] as? [Any], !list.isEmpty else {
                    throw bad("needs a non-empty values list")
                }
                let values = list.compactMap(scalar)
                guard values.count == list.count else { throw bad("values must be scalars") }
                guard Set(values).count == values.count else { throw bad("repeats a value") }
                for value in values {
                    let fits: Bool
                    switch kind {
                    case .string: fits = true
                    case .int: fits = Int(value) != nil
                    case .double: fits = Double(value) != nil
                    case .bool: fits = value == "true" || value == "false"
                    }
                    guard fits else {
                        throw bad("value '\(value)' does not fit the \(kind.rawValue) field '\(field)'")
                    }
                }
                return .jsonFieldIn(field: field, values: values)
            case "json_field_range":
                try only(["field", "min", "max"])
                guard kind == .int || kind == .double else {
                    throw bad("needs an int or double field, '\(field)' is \(kind.rawValue)")
                }
                func limit(_ name: String) throws -> Double? {
                    guard let raw = pair[name], !(raw is NSNull) else { return nil }
                    guard let number = double(raw), number.isFinite else {
                        throw bad("\(name) must be a number")
                    }
                    if kind == .int, number != number.rounded() {
                        throw bad("\(name) must be an integer for the int field '\(field)'")
                    }
                    return number
                }
                let low = try limit("min"), high = try limit("max")
                guard low != nil || high != nil else { throw bad("needs min, max, or both") }
                if let low, let high, low > high { throw bad("has min above max") }
                return .jsonFieldRange(field: field, min: low, max: high)
            default:
                try only(["field", "ladder", "min", "max"])
                guard kind == .string else {
                    throw bad("needs a string field, '\(field)' is \(kind.rawValue)")
                }
                guard let list = pair["ladder"] as? [Any] else { throw bad("needs a ladder list") }
                let ladder = list.compactMap(string)
                guard ladder.count == list.count, ladder.count >= 2 else {
                    throw bad("ladder needs at least two string rungs")
                }
                guard Set(ladder).count == ladder.count else { throw bad("ladder repeats a rung") }
                func rung(_ name: String) throws -> String? {
                    guard let raw = pair[name], !(raw is NSNull) else { return nil }
                    guard let rung = string(raw), ladder.contains(rung) else {
                        throw bad("\(name) must be a rung of the ladder")
                    }
                    return rung
                }
                let low = try rung("min"), high = try rung("max")
                guard low != nil || high != nil else { throw bad("needs min, max, or both") }
                if let low, let high, ladder.firstIndex(of: low)! > ladder.firstIndex(of: high)! {
                    throw bad("has min above max")
                }
                return .jsonFieldRank(field: field, ladder: ladder, min: low, max: high)
            }
        case "max_wall_ms":
            return .maxWallMs(try intArg())
        case "max_output_tokens":
            return .maxOutputTokens(try intArg())
        case "expect_error":
            guard let name = string(value) else {
                throw CaseError.invalidErrorKind(file: file, id: id, value: describe(value))
            }
            if name == "any" { return .expectError(nil) }
            // SPEC §1 grammar: guardrail | refusal | unsupported | context | unavailable | any.
            // `other` exists as a recorded kind but cannot be demanded by a case.
            guard name != ErrorKind.other.rawValue, let kind = ErrorKind(rawValue: name) else {
                throw CaseError.invalidErrorKind(file: file, id: id, value: name)
            }
            return .expectError(kind)
        default:
            throw CaseError.unknownCheck(file: file, id: id, key: key)
        }
    }

    // MARK: scalar helpers

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            // A YAML/JSON boolean bridges to NSNumber too; it is not an integer.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            if n.doubleValue == Double(n.intValue) { return n.intValue }
            return nil
        }
        if let n = value as? Int { return n }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let d = value as? Double { return d }
        if let n = value as? Int { return Double(n) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let n = value as? NSNumber {
            // Only a CFBoolean-backed NSNumber counts as a boolean here. A plain numeric
            // NSNumber (0/1, from YAML/JSON) must NOT fall through to `as? Bool`, which
            // silently bridges numeric NSNumbers to Bool on Darwin.
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil
        }
        if let b = value as? Bool { return b }
        return nil
    }

    /// A YAML/JSON scalar rendered as one string: strings verbatim, booleans as
    /// "true"/"false", integers without a decimal point, doubles via their description.
    private static func scalar(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String { return s }
        if let b = bool(value) { return b ? "true" : "false" }
        if let n = int(value) { return String(n) }
        if let d = double(value) { return String(d) }
        return nil
    }

    private static func describe(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        return String(describing: value)
    }
}
