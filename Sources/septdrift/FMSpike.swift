// septdrift — the CLI surface (SPEC §6).
// Exit codes: 0 ok · 1 flips (diff) or verify failure · 2 model unavailable · 3 validation
// · 4 I/O or incompatible inputs. `run` never exits 1.
import ArgumentParser
import SeptdriftCore
import Foundation

// MARK: - Shared helpers

enum CLI {
    struct ToolError: Error, CustomStringConvertible {
        let description: String
    }

    /// One tool call by absolute path, trimmed. A launch failure, a nonzero status or empty
    /// output is an error: a recording with an empty chip or build has no provenance
    /// (Codex review 0602 #19).
    static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ToolError(description: "\(path): cannot launch: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ToolError(description: "\(path): exit \(process.terminationStatus)")
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ToolError(description: "\(path): no output") }
        return text
    }

    static func err(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Print and leave with a code. ArgumentParser's ExitCode carries the value.
    static func bail(_ message: String, _ code: Int32) -> Never {
        err(message)
        exit(code)
    }

    static func host(noHostname: Bool) throws -> HostInfo {
        HostInfo(
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            osBuild: try tool("/usr/bin/sw_vers", ["-buildVersion"]),
            chip: try tool("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            name: noHostname ? "" : try tool("/bin/hostname", [])
        )
    }

    /// SPEC §6: an input that cannot be read is I/O (exit 4); a readable input that is
    /// wrong is validation (exit 3) (Codex review 0602 #18).
    static func exitCode(for error: CaseError) -> Int32 {
        if case .unreadable = error { return 4 }
        return 3
    }

    static func exitCode(for error: FixtureError) -> Int32 {
        if case .unreadable = error { return 4 }
        return 3
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// `yyyymmdd-HHmmss`, local time, for the default recording filename.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// `name(arg)` per check, comma separated — the check identity of SPEC §5.
    static func checkSummary(_ aCase: Case) -> String {
        aCase.checks.map { "\($0.name)(\($0.arg))" }.joined(separator: ",")
    }
}

// MARK: - Root

@main
struct Septdrift: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "septdrift",
        abstract: "Run declared cases against a language-model backend and diff the recordings.",
        subcommands: [Run.self, Verify.self, Diff.self, Cases.self]
    )
}

// MARK: - run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run every case against a backend and write one recording."
    )

    @Argument(help: "Case file or directory of case files.")
    var casesPath: String

    @Option(name: .long, help: "system | fixture")
    var backend: String

    @Option(name: .long, help: "Fixture JSONL file; required for --backend fixture.")
    var fixtures: String?

    @Option(name: .long, help: "Output recording path.")
    var out: String?

    @Flag(name: .long, help: "Overwrite an existing --out file.")
    var force = false

    @Flag(name: .customLong("no-hostname"), help: "Record an empty host name.")
    var noHostname = false

    @Flag(name: .customLong("no-warm-up"), help: "Skip the unrecorded warm-up call on --backend system.")
    var noWarmUp = false

    /// The warm-up request (SPEC §2): one fixed text case, never recorded, so the first
    /// recorded call does not carry the model's cold start (day 4: M1 3080 ms on call one).
    static let warmUpCase = Case(
        id: "warm-up", prompt: "Reply with the single word ready.", checks: [.contains("ready")])

    func run() async throws {
        // 1. Backend name first: an unknown name is a usage error, not a model call.
        guard backend == "system" || backend == "fixture" else {
            CLI.bail("backend must be system or fixture, got \(backend)", 3)
        }

        // 2. Cases. A validation error stops the run before any model call (SPEC §1).
        let cases: [Case]
        do {
            cases = try CaseLoader.load(path: casesPath)
        } catch let error as CaseError {
            CLI.bail(error.description, CLI.exitCode(for: error))
        } catch {
            CLI.bail(String(describing: error), 4)
        }

        // 3. Backend construction and availability.
        let engine: Backend
        if backend == "fixture" {
            guard let fixtures else {
                CLI.bail("--backend fixture requires --fixtures <file.jsonl>", 3)
            }
            do {
                engine = try FixtureBackend(fileURL: URL(fileURLWithPath: fixtures))
            } catch let error as FixtureError {
                CLI.bail(error.description, CLI.exitCode(for: error))
            } catch {
                CLI.bail(String(describing: error), 4)
            }
        } else {
            let availability = SystemBackend.availability()
            guard availability.available else {
                CLI.bail(availability.reason, 2)
            }
            engine = SystemBackend()
        }

        // 4. Output path. `recordings/` is created when it is missing.
        let hostInfo: HostInfo
        do {
            hostInfo = try CLI.host(noHostname: noHostname)
        } catch {
            CLI.bail("cannot read host facts: \(error)", 4)
        }
        let runID = UUID().uuidString.lowercased()
        let outURL: URL
        if let out {
            outURL = URL(fileURLWithPath: out)
        } else {
            let name = "\(backend)-\(hostInfo.osBuild)-\(CLI.stamp())-\(runID.prefix(8)).jsonl"
            outURL = URL(fileURLWithPath: "recordings").appendingPathComponent(name)
        }
        let directory = outURL.deletingLastPathComponent()
        if !directory.path.isEmpty, !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                CLI.bail("cannot create \(directory.path): \(error)", 4)
            }
        }

        let recorder: Recorder
        do {
            recorder = try Recorder(url: outURL, force: force)
        } catch RecorderError.exists {
            CLI.bail("\(outURL.path) exists; pass --force to overwrite", 4)
        } catch {
            CLI.bail("cannot write \(outURL.path): \(error)", 4)
        }

        // 5. Header before the first model call (SPEC §3).
        do {
            try recorder.writeHeader(
                runID: runID,
                ts: CLI.timestamp(),
                host: hostInfo,
                backend: engine.name,
                casesSHA256: Recorder.casesSHA256(cases),
                expected: cases.map { ExpectedEntry(caseID: $0.id, repeatCount: $0.repeat) }
            )
        } catch {
            CLI.bail("cannot write header: \(error)", 4)
        }

        // 5a. Warm-up: one unrecorded call on the live model, after the header so a crash
        // here still leaves an incomplete file by construction (SPEC §2). Its outcome is
        // printed, never written; a fixture run has no cold start and skips it.
        if backend == "system", !noWarmUp {
            let started = Date()
            let outcome = try? await engine.respond(to: Run.warmUpCase, rep: 0)
            let wallMs = Int((Date().timeIntervalSince(started) * 1000).rounded())
            var line = "warm-up - -/- \(outcome?.wallMs ?? wallMs)ms"
            if let kind = outcome?.error { line += " \(kind.rawValue)" }
            if outcome == nil { line += " other" }
            print(line + " (not recorded)")
        }

        // 6. Serial, file order, one fresh response per (case, rep). No retries (SPEC §2).
        for aCase in cases {
            let requestSHA = Recorder.requestSHA256(for: aCase)
            for rep in 0..<aCase.repeat {
                let result: Result
                do {
                    result = try await engine.respond(to: aCase, rep: rep)
                } catch {
                    // A backend that throws instead of typing the error still yields a record.
                    result = SeptdriftCore.Result(
                        content: "", wallMs: 0, error: .other,
                        errorDetail: String(describing: error))
                }
                let outcomes = Checks.evaluateAll(aCase, on: result)
                let records = zip(aCase.checks, outcomes).map { CheckRecord($0, $1) }
                do {
                    try recorder.writeResult(
                        runID: runID,
                        ts: CLI.timestamp(),
                        caseID: aCase.id,
                        rep: rep,
                        requestSHA256: requestSHA,
                        result: result,
                        checks: records
                    )
                } catch {
                    CLI.bail("cannot write result: \(error)", 4)
                }
                let passed = outcomes.filter(\.pass).count
                var line = "\(aCase.id) \(rep) \(passed)/\(outcomes.count) \(result.wallMs)ms"
                if let kind = result.error { line += " \(kind.rawValue)" }
                print(line)
            }
        }

        // 7. Trailer after the last result.
        do {
            try recorder.writeEnd(runID: runID, ts: CLI.timestamp())
        } catch {
            CLI.bail("cannot write trailer: \(error)", 4)
        }
        print(outURL.path)
    }
}

// MARK: - verify

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Recompute the hash chain of a recording."
    )

    @Argument(help: "Recording JSONL file.")
    var file: String

    func run() throws {
        let outcome = Recorder.verify(url: URL(fileURLWithPath: file))
        print(outcome.message)
        if !outcome.ok { throw ExitCode(1) }
    }
}

// MARK: - cases

struct Cases: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cases",
        abstract: "Validate a case file or directory and list what it declares."
    )

    @Argument(help: "Case file or directory of case files.")
    var casesPath: String

    func run() throws {
        let cases: [Case]
        do {
            cases = try CaseLoader.load(path: casesPath)
        } catch let error as CaseError {
            CLI.bail(error.description, CLI.exitCode(for: error))
        } catch {
            CLI.bail(String(describing: error), 4)
        }
        for aCase in cases {
            print("\(aCase.id)  \(aCase.format.rawValue)  \(aCase.repeat)  \(CLI.checkSummary(aCase))")
        }
    }
}
