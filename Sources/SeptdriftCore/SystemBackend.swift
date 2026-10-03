// SPEC §2 — the live backend: Apple's on-device model through FoundationModels.
// One fresh `LanguageModelSession` per (case, rep); no retries, no prewarm, no deadline.
import Foundation
import FoundationModels

public struct SystemBackend: Backend {

    public var name: String { "system" }

    public init() {}

    /// Checked once before a run (SPEC §2: exit 2 when unavailable, reason printed).
    public static func availability() -> (available: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "available")
        case .unavailable(let reason):
            return (false, String(describing: reason))
        @unknown default:
            return (false, "unknown availability")
        }
    }

    // MARK: request shaping

    /// SPEC §1: context is prepended to the prompt as "Context:\n<context>\n\n".
    static func promptText(for aCase: Case) -> String {
        guard let context = aCase.context, !context.isEmpty else { return aCase.prompt }
        return "Context:\n\(context)\n\n" + aCase.prompt
    }

    /// The declared options, or the framework default when the case declares none.
    static func generationOptions(for aCase: Case) -> GenerationOptions {
        guard let spec = aCase.options else { return GenerationOptions() }
        return GenerationOptions(
            temperature: spec.temperature,
            maximumResponseTokens: spec.maxResponseTokens
        )
    }

    /// Build a flat guided-generation schema from the ordered case schema (SPEC §1).
    static func generationSchema(for fields: [SchemaField]) throws -> GenerationSchema {
        let properties = fields.map { field -> DynamicGenerationSchema.Property in
            let leaf: DynamicGenerationSchema
            switch field.kind {
            case .string: leaf = DynamicGenerationSchema(type: String.self)
            case .int: leaf = DynamicGenerationSchema(type: Int.self)
            case .double: leaf = DynamicGenerationSchema(type: Double.self)
            case .bool: leaf = DynamicGenerationSchema(type: Bool.self)
            }
            return DynamicGenerationSchema.Property(
                name: field.name,
                description: field.description,
                schema: leaf,
                isOptional: field.optional
            )
        }
        let root = DynamicGenerationSchema(name: "Output", properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }

    // MARK: JSON rendering

    static func jsonEscape(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }

    /// Render the generated content as compact JSON with keys in schema order (SPEC §1).
    /// A field the model omitted is omitted here; the checks decide whether that fails.
    static func render(_ content: GeneratedContent, fields: [SchemaField]) -> String {
        var parts: [String] = []
        for field in fields {
            var rendered: String?
            switch field.kind {
            case .string:
                if let v = try? content.value(String?.self, forProperty: field.name) {
                    rendered = jsonEscape(v)
                }
            case .int:
                if let v = try? content.value(Int?.self, forProperty: field.name) {
                    rendered = String(v)
                }
            case .double:
                if let v = try? content.value(Double?.self, forProperty: field.name) {
                    rendered = v == v.rounded() && v.magnitude < 1e15
                        ? String(Int(v)) : String(v)
                }
            case .bool:
                if let v = try? content.value(Bool?.self, forProperty: field.name) {
                    rendered = v ? "true" : "false"
                }
            }
            if let rendered {
                parts.append("\(jsonEscape(field.name)):\(rendered)")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    // MARK: error mapping

    /// SPEC §2 mapping; anything not named there becomes `.other`.
    static func map(_ thrown: LanguageModelSession.GenerationError) -> ErrorKind {
        switch thrown {
        case .guardrailViolation: return .guardrail
        case .refusal: return .refusal
        case .unsupportedGuide, .unsupportedLanguageOrLocale: return .unsupported
        case .exceededContextWindowSize: return .context
        case .assetsUnavailable: return .unavailable
        default: return .other
        }
    }

    /// SPEC §2 mapping for the non-deprecated `LanguageModelError` (macOS 27+).
    static func map(_ thrown: LanguageModelError) -> ErrorKind {
        switch thrown {
        case .guardrailViolation: return .guardrail
        case .refusal: return .refusal
        case .unsupportedCapability, .unsupportedTranscriptContent,
             .unsupportedGenerationGuide, .unsupportedLanguageOrLocale:
            return .unsupported
        case .contextSizeExceeded: return .context
        case .rateLimited, .timeout: return .other
        default: return .other
        }
    }

    // MARK: respond

    public func respond(to aCase: Case, rep: Int) async throws -> Result {
        let session = LanguageModelSession(instructions: aCase.instructions)
        let prompt = Self.promptText(for: aCase)
        let options = Self.generationOptions(for: aCase)

        // Schema build happens before the clock starts; only respond() is timed (SPEC §2).
        var schema: GenerationSchema?
        if aCase.format == .json {
            schema = try Self.generationSchema(for: aCase.schema ?? [])
        }

        let start = DispatchTime.now()
        func elapsedMs() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
        }

        do {
            if let schema {
                let response = try await session.respond(
                    to: prompt, schema: schema, options: options)
                let ms = elapsedMs()
                return Self.result(
                    content: Self.render(response.content, fields: aCase.schema ?? []),
                    wallMs: ms,
                    usage: response.usage,
                    entries: response.transcriptEntries
                )
            } else {
                let response = try await session.respond(to: prompt, options: options)
                let ms = elapsedMs()
                return Self.result(
                    content: response.content,
                    wallMs: ms,
                    usage: response.usage,
                    entries: response.transcriptEntries
                )
            }
        } catch let thrown as LanguageModelError {
            return Result(
                content: "",
                wallMs: elapsedMs(),
                error: Self.map(thrown),
                errorDetail: String(describing: thrown)
            )
        } catch let thrown as LanguageModelSession.GenerationError {
            return Result(
                content: "",
                wallMs: elapsedMs(),
                error: Self.map(thrown),
                errorDetail: String(describing: thrown)
            )
        } catch {
            return Result(
                content: "",
                wallMs: elapsedMs(),
                error: .other,
                errorDetail: String(describing: error)
            )
        }
    }

    private static func result(
        content: String,
        wallMs: Int,
        usage: LanguageModelSession.Usage,
        entries: ArraySlice<Transcript.Entry>
    ) -> Result {
        Result(
            content: content,
            wallMs: wallMs,
            tokensIn: usage.input.totalTokenCount,
            tokensCached: usage.input.cachedTokenCount,
            tokensOut: usage.output.totalTokenCount,
            tokensReasoning: usage.output.reasoningTokenCount,
            assetIDs: entries.compactMap { entry -> [String]? in
                if case .response(let r) = entry { return r.assetIDs }
                return nil
            }.flatMap { $0 }
        )
    }
}
