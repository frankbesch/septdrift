import Foundation

/// One backend response, per SPEC §2.
public struct Result: Sendable, Equatable {
    /// Text, or the JSON rendering for `format: json`. "" on error.
    public var content: String
    public var wallMs: Int
    /// nil when the backend cannot report the count.
    public var tokensIn: Int?
    public var tokensCached: Int?
    public var tokensOut: Int?
    public var tokensReasoning: Int?
    /// [] when unknown.
    public var assetIDs: [String]
    /// Typed error (guardrail, refusal, ...); `content` is "" then.
    public var error: ErrorKind?
    /// The thrown error's description, when there is one.
    public var errorDetail: String?

    public init(
        content: String,
        wallMs: Int,
        tokensIn: Int? = nil,
        tokensCached: Int? = nil,
        tokensOut: Int? = nil,
        tokensReasoning: Int? = nil,
        assetIDs: [String] = [],
        error: ErrorKind? = nil,
        errorDetail: String? = nil
    ) {
        self.content = content
        self.wallMs = wallMs
        self.tokensIn = tokensIn
        self.tokensCached = tokensCached
        self.tokensOut = tokensOut
        self.tokensReasoning = tokensReasoning
        self.assetIDs = assetIDs
        self.error = error
        self.errorDetail = errorDetail
    }
}
