#!/bin/sh
# run.sh -- drive test/e2e/ end-to-end against a built Kakoune binary.
#
# The harness launches `kak -ui json` headless, sources rc/tools/llm.kak wired
# to the deterministic test/e2e/mock-qwen.sh shim, then drives the real
# :llm-* commands (session / accept / reject / approve / stop) over stdin
# JSON-RPC and asserts on on-disk state. No network access required.
#
# Usage:
#   ./test/e2e/run.sh                 # all scenarios against src/kak
#   E2E_SCENARIO=accept ./test/e2e/run.sh
#   KAK_BIN=/path/to/kak ./test/e2e/run.sh
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
    echo "run.sh: python3 is required but not found in PATH" >&2
    exit 1
fi

KAK_BIN="${KAK_BIN:-src/kak}"
if [ ! -x "$KAK_BIN" ]; then
    echo "run.sh: Kakoune binary not found at $KAK_BIN (build with: make)" >&2
    exit 1
fi

SCENARIOS="accept reject control stop"
LOG_DIR="$(dirname "$0")/logs"
mkdir -p "$LOG_DIR"
fail=0
for scenario in $SCENARIOS; do
    # The control scenario exercises the :llm-approve round-trip; the same
    # deterministic request id is used by test/regression/ (issue 6341).
    # NB: must be *exported* -- a bare assignment is not inherited by the
    # python3 child, so the shim would never receive --control-request.
    if [ "$scenario" = "control" ]; then
        export E2E_CONTROL_REQUEST="req-42"
    else
        unset E2E_CONTROL_REQUEST || true
    fi
    output_file="$LOG_DIR/${scenario}.log"
    if E2E_SCENARIO="$scenario" KAK_BIN="$KAK_BIN" \
        python3 "$(dirname "$0")/e2e_driver.py" >"$output_file" 2>&1; then
        echo "  [ok] $scenario"
    else
        echo "  [FAIL] $scenario — see $output_file" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "run.sh: one or more scenarios failed" >&2
    exit 1
fi
echo "run.sh: all scenarios passed"
