#!/bin/sh
# run-ghost.sh -- drive test/e2e/ ghost end-to-end against a built Kakoune.
#
# The harness launches `kak -ui json` headless, sources rc/tools/ghost.kak with
# the tailer pointed at the REAL rc/tools/ghost_ws.py, then drives the real
# :ghost-session / :ghost-control / :ghost-reject / :ghost-stop commands over
# stdin JSON-RPC. The bridge side is a mock WebSocket server
# (ghost_ws_server.py) playing the ghost-text-agent -- no Flink/OpenAI needed,
# and this is the first end-to-end exercise of the real tailer.
#
# Usage:
#   ./test/e2e/run-ghost.sh                      # all ghost scenarios
#   E2E_GHOST_SCENARIO=ws_stop ./test/e2e/run-ghost.sh
#   KAK_BIN=/path/to/kak ./test/e2e/run-ghost.sh
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
    echo "run-ghost.sh: python3 is required but not found in PATH" >&2
    exit 1
fi

# NOTE: the default KAK_BIN is cwd-relative -- run this script from the repo
# root, or export an absolute KAK_BIN (see ghost_e2e.py's import note).
KAK_BIN="${KAK_BIN:-src/kak}"
if [ ! -x "$KAK_BIN" ]; then
    echo "run-ghost.sh: Kakoune binary not found at $KAK_BIN (build with: make)" >&2
    exit 1
fi

# Per-run marker so concurrent harness runs don't match each other's tailer PIDs.
export GHOST_E2E_RUN_ID="ghost-e2e-$(date +%s)-$$"

# Clean up any kak / tailer / mock-bridge left by a crashed run (the harness
# also tears these down per scenario; this is the belt-and-braces sweep).
# NOTE: the "kak -ui json" match is broad -- it also kills other headless
# JSON-UI sessions on this host, not just this run's.
cleanup() {
    pkill -9 -f "kak -ui json" 2>/dev/null || true
    pkill -9 -f "rc/tools/ghost_ws\.py" 2>/dev/null || true
    pkill -9 -f "ghost_ws_server\.py" 2>/dev/null || true
}
trap cleanup EXIT

SCENARIOS="ws_accept ws_reject ws_stop"
[ -n "${E2E_GHOST_SCENARIO:-}" ] && SCENARIOS="$E2E_GHOST_SCENARIO"

LOG_DIR="$(dirname "$0")/logs-ghost"
mkdir -p "$LOG_DIR"
fail=0
for scenario in $SCENARIOS; do
    output_file="$LOG_DIR/${scenario}.log"
    if KAK_BIN="$KAK_BIN" \
        python3 "$(dirname "$0")/ghost_e2e.py" "$scenario" >"$output_file" 2>&1; then
        echo "  [ok] $scenario"
    else
        echo "  [FAIL] $scenario -- see $output_file" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "run-ghost.sh: one or more scenarios failed" >&2
    exit 1
fi
echo "run-ghost.sh: all ghost scenarios passed"
