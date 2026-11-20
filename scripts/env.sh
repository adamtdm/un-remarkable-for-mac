# Shared build environment. With only the Command Line Tools installed, the newest SDK may
# need macro plugins (SwiftUI's @State) that the CLT doesn't ship; pin the newest SDK that works.
if ! xcode-select -p | grep -q Xcode.app; then
  for sdk in MacOSX26.5.sdk MacOSX26.sdk; do
    if [[ -d /Library/Developer/CommandLineTools/SDKs/$sdk ]]; then
      export SDKROOT=/Library/Developer/CommandLineTools/SDKs/$sdk
      break
    fi
  done
fi
