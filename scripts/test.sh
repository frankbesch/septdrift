#!/bin/bash
# Run the test suite: fixture backend only, no model calls.
# Under Command Line Tools without Xcode, swift test needs the Swift Testing
# macro plugin path; with Xcode installed it is found on its own.
# FM_SCRATCH moves build products out of a synced folder (iCloud extended
# attributes make codesign reject the .xctest bundle).
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
if [ -n "${FM_SCRATCH:-}" ]; then args+=(--scratch-path "$FM_SCRATCH"); fi
CLT=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if ! xcode-select -p 2>/dev/null | grep -q 'Xcode.*\.app' && [ -d "$CLT" ]; then
  args+=(-Xswiftc -plugin-path -Xswiftc "$CLT")
fi
exec swift test ${args[@]+"${args[@]}"} "$@"
