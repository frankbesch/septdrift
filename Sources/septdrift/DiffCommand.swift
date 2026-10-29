// septdrift diff (SPEC §5, §6). Scoring lives in SeptdriftCore.Diff; this file is the shell.
import ArgumentParser
import SeptdriftCore
import Foundation

struct Diff: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Score one recording against another."
    )

    @Argument(help: "Recording A (the baseline).")
    var a: String

    @Argument(help: "Recording B (the candidate).")
    var b: String

    @Flag(name: .long, help: "Emit the scorecard as JSON.")
    var json = false

    @Flag(name: .customLong("fail-on-fix"), help: "Count fixes toward the failing exit code.")
    var failOnFix = false

    @Flag(name: .customLong("allow-request-drift"), help: "Tolerate a differing requestSHA256.")
    var allowRequestDrift = false

    @Option(name: .long, help: "Pass-rate change treated as noise, 0 <= rate < 1.")
    var tolerance: Double = 0

    func run() throws {
        guard tolerance >= 0, tolerance < 1 else {
            CLI.bail("--tolerance must be in [0, 1): \(tolerance)", 3)
        }
        let options = DiffOptions(
            failOnFix: failOnFix, allowRequestDrift: allowRequestDrift, tolerance: tolerance)
        let scorecard: Scorecard
        do {
            scorecard = try SeptdriftCore.Diff.diff(
                a: URL(fileURLWithPath: a), b: URL(fileURLWithPath: b), options: options)
        } catch let error as DiffError {
            CLI.bail(String(describing: error), 4)
        } catch {
            CLI.bail(String(describing: error), 4)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            do {
                let data = try encoder.encode(scorecard)
                print(String(decoding: data, as: UTF8.self))
            } catch {
                CLI.bail("cannot encode the scorecard: \(error)", 4)
            }
        } else {
            print(SeptdriftCore.Diff.render(scorecard))
        }

        let code = scorecard.exitCode
        if code != 0 { throw ExitCode(code) }
    }
}
