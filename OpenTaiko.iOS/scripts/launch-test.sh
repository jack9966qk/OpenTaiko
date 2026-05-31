#!/usr/bin/env bash
# Build, deploy to the simulator, and report whether the app launched cleanly or
# crashed at startup. Used to validate that a change does not abort the Mono runtime.
#
# Usage: ./scripts/launch-test.sh [--clean] [--release] [--wait N]
#   --clean    forwarded to deploy.sh (clean build + reinstall)
#   --release  forwarded to deploy.sh (Release/AOT build)
#   --wait N   seconds to observe console output (default 12)
#
# Exit codes: 0 = launched (saw ViewDidLayoutSubviews, no SIGABRT)
#             1 = crashed at startup (SIGABRT) or never reached first frame
#             2 = build failed

set -uo pipefail
cd "$(dirname "$0")/.."

WAIT=12
CLEAN_ARG=""
RELEASE_ARG=""
for arg in "$@"; do
	case "$arg" in
		--clean) CLEAN_ARG="--clean" ;;
		--release) RELEASE_ARG="--release" ;;
		--wait) ;; # handled below
		*) if [[ "${PREV:-}" == "--wait" ]]; then WAIT="$arg"; fi ;;
	esac
	PREV="$arg"
done

LOG="$(mktemp -t opentaiko-launchtest)"
echo "==> Running deploy (clean=${CLEAN_ARG:-no}, release=${RELEASE_ARG:-no}, wait=${WAIT}s)..."
./scripts/deploy.sh $CLEAN_ARG $RELEASE_ARG --wait "$WAIT" >"$LOG" 2>&1

if grep -q "error CS" "$LOG" || grep -q "Build FAILED" "$LOG"; then
	echo "RESULT: BUILD FAILED"
	grep -E "error CS|Build FAILED" "$LOG" | head -10
	echo "(full log: $LOG)"
	exit 2
fi

FRAMES=$(grep -c "ViewDidLayoutSubviews" "$LOG")
CRASH=$(grep -c "Got a SIGABRT\|Native Crash Reporting" "$LOG")

if [[ "$CRASH" -gt 0 ]]; then
	echo "RESULT: CRASHED AT STARTUP"
	echo "--- crashing frame (top of native stacktrace) ---"
	grep -A6 "Native stacktrace:" "$LOG" | sed 's|/Users.*dylib|<dylib>|' | head -8
	echo "(full log: $LOG)"
	exit 1
fi

if [[ "$FRAMES" -gt 0 ]]; then
	echo "RESULT: LAUNCHED OK (reached first frame x$FRAMES)"
	echo "(full log: $LOG)"
	exit 0
fi

echo "RESULT: NO FRAME, NO CRASH (inconclusive — app may not have started)"
echo "(full log: $LOG)"
exit 1
