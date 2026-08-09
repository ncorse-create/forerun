#!/bin/bash
# Compile check only. Generic iOS destination: no simulator boot, no device needed.
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/forerun-build.log
xcodebuild -project "$ROOT/Forerun.xcodeproj" \
  -scheme Forerun \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ForerunDD \
  CODE_SIGNING_ALLOWED=NO \
  build > "$LOG" 2>&1
status=$?
if grep -q "BUILD SUCCEEDED" "$LOG"; then
  echo "BUILD SUCCEEDED"
  grep -c "warning:" "$LOG" | xargs -I{} echo "warnings: {}"
  grep "warning:" "$LOG" | sort -u | head -30
else
  echo "BUILD FAILED (xcodebuild exit $status)"
  grep -E "error:|BUILD FAILED" "$LOG" | sort -u | head -40
fi
exit $status
