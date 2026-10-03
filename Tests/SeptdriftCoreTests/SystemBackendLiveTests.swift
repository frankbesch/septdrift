// Live smoke for SystemBackend. Skipped unless FM_LIVE=1, so the CI gate stays at zero
// live calls (SPEC §7). Cases mirror `cases/day2.yaml` inline, so this does not depend on
// the case loader.
import Foundation
import Testing
@testable import SeptdriftCore

private let liveEnabled = ProcessInfo.processInfo.environment["FM_LIVE"] == "1"

@Test("live: afe-with-context and ordered-json through SystemBackend",
      .enabled(if: liveEnabled))
func systemBackendLiveSmoke() async throws {
    let availability = SystemBackend.availability()
    print("availability: \(availability)")
    try #require(availability.available)

    let backend = SystemBackend()

    let afe = Case(
        id: "afe-with-context",
        instructions: "Answer in one plain sentence. Use only the context given.",
        context: "AFE = Authorization for Expenditure: the operator's request that "
            + "working-interest partners approve their share of a well's estimated cost.",
        prompt: "In one sentence, what is an AFE in oil and gas?",
        checks: [.contains("Authorization for Expenditure")]
    )

    let json = Case(
        id: "ordered-json",
        prompt: "Return kind request, count 3, and approved true.",
        format: .json,
        schema: [
            SchemaField(name: "kind", kind: .string),
            SchemaField(name: "count", kind: .int),
            SchemaField(name: "approved", kind: .bool)
        ],
        checks: [.jsonFieldEquals(field: "kind", value: "request")]
    )

    for aCase in [afe, json] {
        let r = try await backend.respond(to: aCase, rep: 0)
        print("""
            --- \(aCase.id)
            content: \(r.content)
            wallMs: \(r.wallMs)
            tokens: in=\(String(describing: r.tokensIn)) cached=\(String(describing: r.tokensCached)) \
            out=\(String(describing: r.tokensOut)) reasoning=\(String(describing: r.tokensReasoning))
            assetIDs: \(r.assetIDs)
            error: \(String(describing: r.error)) detail: \(String(describing: r.errorDetail))
            """)
    }
}
