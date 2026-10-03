// SPEC §2 — the backend seam. One call per (case, rep); the caller owns sequencing.
import Foundation

/// A source of answers for a `Case`. Implementations are value types and `Sendable`
/// so the runner can hold one across the whole run.
public protocol Backend: Sendable {
    /// "system" | "fixture" — recorded in the run header (SPEC §3).
    var name: String { get }

    /// Answer one repetition of one case. `rep` is 0-based (SPEC §2).
    func respond(to aCase: Case, rep: Int) async throws -> Result
}
