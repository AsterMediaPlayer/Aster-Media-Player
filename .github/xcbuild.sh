#!/bin/bash
# Used by CI: builds the AsterFIN scheme, unsigned, for one platform.
#   .github/xcbuild.sh <name for the log> <xcodebuild destination>
set -o pipefail
log="build-$1.log"
xcodebuild build \
  -project AsterFIN.xcodeproj -scheme AsterFIN -configuration Debug \
  -destination "$2" ARCHS=arm64 -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  | tee "$log" | grep -E '(: error:|\*\* BUILD)' || true
grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"
