// SPEC §5 — diff two recordings into a scorecard.
//
// Preconditions (exit 4): both sides verify, both are complete, and `casesSHA256` matches
// unless `--allow-request-drift` is given. Pairing is by caseID; scoring is per check
// identity (name, arg) over the pass rate across reps.
import Foundation

/// `diff` flags (SPEC §5, §6).
public struct DiffOptions: Sendable {
    /// `--fail-on-fix`: a fix also makes the exit code 1.
    public var failOnFix: Bool
    /// `--allow-request-drift`: tolerate a different `casesSHA256`; pairs whose
    /// `requestSHA256` differs are listed and excluded.
    public var allowRequestDrift: Bool

    public init(failOnFix: Bool = false, allowRequestDrift: Bool = false) {
        self.failOnFix = failOnFix
        self.allowRequestDrift = allowRequestDrift
    }
}

/// A violated precondition. The CLI maps every case to exit 4 (SPEC §5, §6).
public enum DiffError: Error, Equatable, CustomStringConvertible {
    /// A side failed `Recorder.verify`; the verifier's own message is carried.
    case notVerified(side: String, message: String)
    /// A side has no `end` trailer.
    case incomplete(side: String)
    /// `casesSHA256` differs and `--allow-request-drift` was not given.
    case casesChanged(a: String, b: String)
    /// A side could not be read at all.
    case unreadable(side: String, message: String)

    public var description: String {
        switch self {
        case .notVerified(let side, let message):
            return "side \(side) does not verify: \(message)"
        case .incomplete(let side):
            return "side \(side) is incomplete"
        case .casesChanged(let a, let b):
            return "casesSHA256 differ (A \(Self.short(a)), B \(Self.short(b))); "
                + "pass --allow-request-drift to compare anyway"
        case .unreadable(let side, let message):
            return "side \(side) cannot be read: \(message)"
        }
    }

    private static func short(_ hash: String) -> String { String(hash.prefix(12)) }
}

/// How one check moved between the two sides (SPEC §5).
public enum DiffClass: String, Sendable, Codable, CaseIterable {
    /// rateA == 1.0 and rateB < 1.0. The only class that fails the run.
    case flip
    /// rateB < rateA, and not a flip.
    case degrade
    /// rateA < 1.0 and rateB == 1.0.
    case fix
    /// Both sides present and rateA == rateB.
    case unchanged
    /// rateB > rateA but still below 1.0. Reported only; not counted (house rule, not SPEC §5).
    case improved
    /// Present on B only.
    case added
    /// Present on A only.
    case removed
}

/// One side's header block: identity, assets, medians and error-kind counts (SPEC §5).
public struct Side: Sendable, Encodable, Equatable {
    public var backend: String
    public var chip: String
    public var osBuild: String
    /// Distinct, sorted, over every result record on this side.
    public var assetIDs: [String]
    /// Median over non-error results; nil when there are none.
    public var medianWallMs: Int?
    /// Median over non-error results that report `tokensOut`; nil when there are none.
    public var medianTokensOut: Int?
    /// Count per `ErrorKind` raw value; only non-zero kinds appear.
    public var errorKinds: [String: Int]

    public init(
        backend: String, chip: String, osBuild: String, assetIDs: [String],
        medianWallMs: Int?, medianTokensOut: Int?, errorKinds: [String: Int]
    ) {
        self.backend = backend
        self.chip = chip
        self.osBuild = osBuild
        self.assetIDs = assetIDs
        self.medianWallMs = medianWallMs
        self.medianTokensOut = medianTokensOut
        self.errorKinds = errorKinds
    }
}

/// One scored check identity on one paired case.
public struct Row: Sendable, Encodable, Equatable {
    public var caseID: String
    /// The check identity, rendered `name:arg`.
    public var check: String
    /// passes / reps on A; nil when the check is absent from A.
    public var rateA: Double?
    public var rateB: Double?
    public var klass: DiffClass
    // Kept so the text scorecard can render "3/3"; the rates above are the SPEC §5 values.
    public var passesA: Int?
    public var repsA: Int?
    public var passesB: Int?
    public var repsB: Int?

    public init(
        caseID: String, check: String, rateA: Double?, rateB: Double?, klass: DiffClass,
        passesA: Int? = nil, repsA: Int? = nil, passesB: Int? = nil, repsB: Int? = nil
    ) {
        self.caseID = caseID
        self.check = check
        self.rateA = rateA
        self.rateB = rateB
        self.klass = klass
        self.passesA = passesA
        self.repsA = repsA
        self.passesB = passesB
        self.repsB = repsB
    }

    /// rateB - rateA; nil when either side is absent.
    public var delta: Double? {
        guard let a = rateA, let b = rateB else { return nil }
        return b - a
    }

    private enum CodingKeys: String, CodingKey {
        case caseID, check, rateA, rateB, klass, passesA, repsA, passesB, repsB, delta
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(caseID, forKey: .caseID)
        try container.encode(check, forKey: .check)
        try container.encode(rateA, forKey: .rateA)
        try container.encode(rateB, forKey: .rateB)
        try container.encode(klass, forKey: .klass)
        try container.encode(passesA, forKey: .passesA)
        try container.encode(repsA, forKey: .repsA)
        try container.encode(passesB, forKey: .passesB)
        try container.encode(repsB, forKey: .repsB)
        try container.encode(delta, forKey: .delta)
    }
}

/// One count per row class, so the counts sum to the number of rows. Only `flips` (and
/// `fixes` under `--fail-on-fix`) decide the exit code.
public struct DiffCounts: Sendable, Encodable, Equatable {
    public var flips: Int
    public var degrades: Int
    public var fixes: Int
    public var unchanged: Int
    public var improved: Int
    public var added: Int
    public var removed: Int

    public init(
        flips: Int = 0, degrades: Int = 0, fixes: Int = 0, unchanged: Int = 0,
        improved: Int = 0, added: Int = 0, removed: Int = 0
    ) {
        self.flips = flips
        self.degrades = degrades
        self.fixes = fixes
        self.unchanged = unchanged
        self.improved = improved
        self.added = added
        self.removed = removed
    }

    public var total: Int { flips + degrades + fixes + unchanged + improved + added + removed }
}

/// The whole `diff` answer. `--json` encodes this value.
public struct Scorecard: Sendable, Encodable, Equatable {
    /// Exactly two entries: A then B.
    public var sides: [Side]
    /// Sorted by caseID, then by check identity.
    public var rows: [Row]
    public var onlyInA: [String]
    public var onlyInB: [String]
    /// caseIDs excluded because `requestSHA256` differed (only with `allowRequestDrift`).
    public var requestChanged: [String]
    public var counts: DiffCounts
    public var exitCode: Int32

    public init(
        sides: [Side], rows: [Row], onlyInA: [String], onlyInB: [String],
        requestChanged: [String], counts: DiffCounts, exitCode: Int32
    ) {
        self.sides = sides
        self.rows = rows
        self.onlyInA = onlyInA
        self.onlyInB = onlyInB
        self.requestChanged = requestChanged
        self.counts = counts
        self.exitCode = exitCode
    }
}

public enum Diff {

    // MARK: - Entry point

    /// SPEC §5. Verifies both sides, then scores them.
    public static func diff(a: URL, b: URL, options: DiffOptions) throws -> Scorecard {
        let sideA = try load(a, label: "A")
        let sideB = try load(b, label: "B")

        if sideA.header.casesSHA256 != sideB.header.casesSHA256, !options.allowRequestDrift {
            throw DiffError.casesChanged(
                a: sideA.header.casesSHA256, b: sideB.header.casesSHA256)
        }

        return score(sideA, sideB, options: options)
    }

    // MARK: - Loading

    private struct Loaded {
        var header: RunHeader
        var results: [ResultRecord]
    }

    /// One read per side: the bytes that verify are the bytes that are scored
    /// (Codex review 0602 #8).
    private static func load(_ url: URL, label: String) throws -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DiffError.unreadable(side: label, message: error.localizedDescription)
        }
        let verdict = Recorder.verify(data: data)
        if !verdict.ok {
            let message = verdict.failure ?? "failed"
            if message == "incomplete" { throw DiffError.incomplete(side: label) }
            throw DiffError.notVerified(side: label, message: message)
        }
        let parsed: (header: RunHeader, results: [ResultRecord], end: EndRecord?)
        do {
            parsed = try Recorder.read(data: data)
        } catch {
            throw DiffError.unreadable(side: label, message: String(describing: error))
        }
        guard parsed.end != nil else { throw DiffError.incomplete(side: label) }
        return Loaded(header: parsed.header, results: parsed.results)
    }

    // MARK: - Scoring

    private struct Tally {
        var passes = 0
        var reps = 0
        var rate: Double { reps == 0 ? 0 : Double(passes) / Double(reps) }
    }

    private static func score(_ a: Loaded, _ b: Loaded, options: DiffOptions) -> Scorecard {
        let sides = [side(a), side(b)]

        let casesA = caseIDs(a)
        let casesB = caseIDs(b)
        let onlyInA = casesA.subtracting(casesB).sorted()
        let onlyInB = casesB.subtracting(casesA).sorted()
        var paired = casesA.intersection(casesB)

        // Request drift: a paired case whose requestSHA256 set differs is excluded.
        var requestChanged: [String] = []
        if options.allowRequestDrift {
            let requestsA = requests(a)
            let requestsB = requests(b)
            for id in paired.sorted() where requestsA[id] != requestsB[id] {
                requestChanged.append(id)
                paired.remove(id)
            }
        }

        let tallyA = tallies(a)
        let tallyB = tallies(b)

        var rows: [Row] = []
        var counts = DiffCounts()
        for id in paired {
            let checksA = tallyA[id] ?? [:]
            let checksB = tallyB[id] ?? [:]
            let identities = Set(checksA.keys).union(checksB.keys)
            for identity in identities {
                let left = checksA[identity]
                let right = checksB[identity]
                let klass = classify(left, right)
                switch klass {
                case .flip: counts.flips += 1
                case .degrade: counts.degrades += 1
                case .fix: counts.fixes += 1
                case .unchanged: counts.unchanged += 1
                case .improved: counts.improved += 1
                case .added: counts.added += 1
                case .removed: counts.removed += 1
                }
                rows.append(Row(
                    caseID: id,
                    check: identity,
                    rateA: left?.rate,
                    rateB: right?.rate,
                    klass: klass,
                    passesA: left?.passes, repsA: left?.reps,
                    passesB: right?.passes, repsB: right?.reps))
            }
        }
        rows.sort { ($0.caseID, $0.check) < ($1.caseID, $1.check) }

        let failing = counts.flips > 0 || (options.failOnFix && counts.fixes > 0)
        return Scorecard(
            sides: sides, rows: rows, onlyInA: onlyInA, onlyInB: onlyInB,
            requestChanged: requestChanged, counts: counts,
            exitCode: failing ? 1 : 0)
    }

    /// SPEC §5 classification, in order: flip, fix, degrade, unchanged; `improved` is the
    /// leftover case (rateB > rateA, rateB < 1.0), reported but never counted.
    private static func classify(_ a: Tally?, _ b: Tally?) -> DiffClass {
        guard let a else { return b == nil ? .unchanged : .added }
        guard let b else { return .removed }
        let rateA = a.rate
        let rateB = b.rate
        if rateA == 1.0 && rateB < 1.0 { return .flip }
        if rateA < 1.0 && rateB == 1.0 { return .fix }
        if rateB < rateA { return .degrade }
        if rateA == rateB { return .unchanged }
        return .improved
    }

    // MARK: - Per-side aggregation

    private static func caseIDs(_ side: Loaded) -> Set<String> {
        Set(side.results.map(\.caseID))
    }

    private static func requests(_ side: Loaded) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for record in side.results {
            out[record.caseID, default: []].insert(record.requestSHA256)
        }
        return out
    }

    /// caseID -> check identity ("name:arg") -> passes/reps.
    private static func tallies(_ side: Loaded) -> [String: [String: Tally]] {
        var out: [String: [String: Tally]] = [:]
        for record in side.results {
            for check in record.checks {
                let identity = self.identity(name: check.name, arg: check.arg)
                var tally = out[record.caseID, default: [:]][identity] ?? Tally()
                tally.reps += 1
                if check.pass { tally.passes += 1 }
                out[record.caseID, default: [:]][identity] = tally
            }
        }
        return out
    }

    /// The check identity as rendered in the scorecard and the JSON.
    public static func identity(name: String, arg: String) -> String { "\(name):\(arg)" }

    private static func side(_ loaded: Loaded) -> Side {
        let assets = Set(loaded.results.flatMap(\.result.assetIDs)).sorted()
        let clean = loaded.results.filter { $0.result.error == nil }
        var kinds: [String: Int] = [:]
        for record in loaded.results {
            if let kind = record.result.error { kinds[kind.rawValue, default: 0] += 1 }
        }
        return Side(
            backend: loaded.header.backend,
            chip: loaded.header.host.chip,
            osBuild: loaded.header.host.osBuild,
            assetIDs: assets,
            medianWallMs: median(clean.map(\.result.wallMs)),
            medianTokensOut: median(clean.compactMap(\.result.tokensOut)),
            errorKinds: kinds)
    }

    /// Median; an even count is the mean of the two middle values, rounded half up (SPEC §5).
    static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        let a = sorted[n / 2 - 1]
        let b = sorted[n / 2]
        // Overflow-safe half-up mean of two non-negative Ints (wallMs, tokensOut).
        let base = a / 2 + b / 2
        let remainder = a % 2 + b % 2
        return remainder > 0 ? base + 1 : base
    }

    // MARK: - Rendering

    /// The plain-text scorecard written to stdout when `--json` is absent.
    public static func render(_ s: Scorecard) -> String {
        var out: [String] = []
        let labels = ["A", "B"]
        for (index, side) in s.sides.enumerated() {
            let label = index < labels.count ? labels[index] : String(index)
            let assets = side.assetIDs.isEmpty ? "-" : side.assetIDs.joined(separator: ",")
            let errors = side.errorKinds.isEmpty
                ? "-"
                : side.errorKinds.keys.sorted().map { "\($0)=\(side.errorKinds[$0]!)" }
                    .joined(separator: ",")
            out.append(
                "side \(label): backend=\(side.backend) chip=\(side.chip) "
                + "osBuild=\(side.osBuild) assets=\(assets) "
                + "medianWallMs=\(number(side.medianWallMs)) "
                + "medianTokensOut=\(number(side.medianTokensOut)) errors=\(errors)")
        }
        out.append("")

        let header = ["caseID", "check", "rateA", "rateB", "Δ", "class"]
        var table: [[String]] = [header]
        for row in s.rows {
            table.append([
                row.caseID,
                row.check,
                rate(row.passesA, row.repsA),
                rate(row.passesB, row.repsB),
                delta(row.delta),
                row.klass.rawValue,
            ])
        }
        out.append(contentsOf: columns(table))
        out.append("")

        out.append("only in A: \(list(s.onlyInA))")
        out.append("only in B: \(list(s.onlyInB))")
        out.append("request changed: \(list(s.requestChanged))")
        out.append(
            "counts: flips=\(s.counts.flips) degrades=\(s.counts.degrades) "
            + "fixes=\(s.counts.fixes) unchanged=\(s.counts.unchanged) "
            + "improved=\(s.counts.improved) added=\(s.counts.added) removed=\(s.counts.removed)")
        out.append("exit: \(s.exitCode)")
        return out.joined(separator: "\n") + "\n"
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "-" : items.joined(separator: ", ")
    }

    private static func number(_ value: Int?) -> String {
        value.map(String.init) ?? "-"
    }

    /// "3/3 (1.000)"; "-" when the check is absent from that side.
    private static func rate(_ passes: Int?, _ reps: Int?) -> String {
        guard let passes, let reps, reps > 0 else { return "-" }
        let value = Double(passes) / Double(reps)
        return "\(passes)/\(reps) (\(String(format: "%.3f", value)))"
    }

    private static func delta(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%+.3f", value)
    }

    /// Left-aligned fixed-width columns, two spaces between them.
    private static func columns(_ rows: [[String]]) -> [String] {
        guard let first = rows.first else { return [] }
        var widths = [Int](repeating: 0, count: first.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1
                    ? cell
                    : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }
}
