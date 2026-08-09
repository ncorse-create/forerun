#!/bin/bash
# Engine gate. Runs the pure-Swift core tests on macOS. No simulator, ever.
set -o pipefail
cd "$(dirname "$0")/../Packages/ForerunCore" || exit 1
swift test --disable-sandbox 2>&1 | tee /tmp/forerun-core-test.log
status=${PIPESTATUS[0]}
echo "--- swift test exit: $status"
grep -E "error:|Test run with .* failed|Executed .* tests" /tmp/forerun-core-test.log | tail -20
exit $status
