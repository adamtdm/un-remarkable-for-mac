#!/bin/zsh
# Runs the RMKit test suite. Works with only the Command Line Tools installed (no Xcode),
# where Swift Testing lives outside the default search paths.
set -e
cd "$(dirname "$0")/.."
source scripts/env.sh
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
P=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if xcode-select -p | grep -q Xcode.app; then
  exec swift test "$@"
fi
exec swift test --build-system native \
  -Xswiftc -F$F -Xswiftc -plugin-path -Xswiftc $P \
  -Xlinker -F$F -Xlinker -rpath -Xlinker $F "$@"
