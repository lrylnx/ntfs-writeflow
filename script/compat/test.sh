#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p build/compat-tests
for ARCH in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -target "$ARCH-apple-macos13.0" \
        Sources/Core/VolumeRecord.swift Sources/Compatibility/Protocol.swift Sources/Compatibility/Command.swift \
        Tests/Compatibility/PolicyTests.swift -framework Security -o "build/compat-tests/policy-$ARCH"
done
"build/compat-tests/policy-$(uname -m)"
python3 Tests/Compatibility/signing_continuity.py build/compat/NTFSWriteFlowCompat.app
python3 script/compat/verify.py build/compat/NTFSWriteFlowCompat.app > build/compat-tests/artifact-verification.json
python3 -m unittest discover -s Tests -p test_signing_gate.py
