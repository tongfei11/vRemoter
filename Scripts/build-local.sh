#!/bin/zsh
# Local executable only, no distribution package or analytics dependency.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc -O -D LOCAL_BUILD -D DEBUG Sources/vRemote/**/*.swift -o .build/vRemote-local
