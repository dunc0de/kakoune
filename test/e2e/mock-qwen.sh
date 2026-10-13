#!/bin/sh
# mock-qwen.sh -- deterministic stand-in for the Qwen Code CLI used by tests/e2e/.
#
# It speaks exactly the CLI contract that rc/tools/llm.kak's `llm-session`
# command relies on, so the real module can drive it end-to-end without any
# network access:
#
#   <llm_cmd> [--model <m>] [llm_args...] --prompt \
#       --json-file <fifo> --input-file <regular>
#
# Contract details (see llm.kak):
#   * --json-file  is a FIFO the harness opens O_RDWR and reads events from
#                  directly in Python (test/e2e/e2e_driver.py::stream_deltas);
#                  the shim only ever writes it, so an O_WRONLY open here never
#                  blocks even though no tailer connects.
#   * --input-file is a regular file used as the control channel: :llm-approve
#                  appends confirmation_response lines to it that the shim reads
#                  when it emits a control_request.
#
# The shim emits the event JSON schema the harness parses:
#   {"event":{"type":"session_start"},"data":{"supported_events":["control_request"]}}
#   {"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}}
#   {"event":{"type":"control_request"},"request_id":"<id>"}
#
# Usage:
#   mock-qwen.sh [--model M] [--tokens a,b,c] [--delay SECONDS] \
#       [--control-request ID] [--control-wait SECONDS] \
#       --json-file FIFO --input-file FILE
set -e

MODEL=""
PROMPT=0
JSON_FILE=""
INPUT_FILE=""
TOKENS="Hello,world"
DELAY="0.05"
CONTROL_REQUEST=""
CONTROL_WAIT="10"

while [ $# -gt 0 ]; do
    case "$1" in
        --model)     MODEL="${2:-}"; shift 2 ;;
        --prompt)    PROMPT=1; shift ;;                 # valueless flag (prompt via stdin in prod)
        --json-file) JSON_FILE="${2:-}"; shift 2 ;;
        --input-file) INPUT_FILE="${2:-}"; shift 2 ;;
        --tokens)
            # Tokens arrive as *separate* argv elements (see main():
            # ["--tokens"] + tokens + ["--delay", ...]). Consume the value plus
            # any trailing positional args until the next flag, so multi-token
            # deltas like "Hello world" are not silently dropped. An explicit
            # --tokens fully replaces the default token list, so reset first.
            shift
            TOKENS=""
            while [ $# -gt 0 ]; do
                case "$1" in --*) break ;; esac
                TOKENS="${TOKENS:+$TOKENS,}$1"; shift
            done ;;
        --delay)     DELAY="${2:-$DELAY}"; shift 2 ;;
        --control-request) CONTROL_REQUEST="${2:-}"; shift 2 ;;
        --control-wait)      CONTROL_WAIT="${2:-$CONTROL_WAIT}"; shift 2 ;;
        *) shift ;;                                # ignore stray llm_args
    esac
done

if [ -z "$JSON_FILE" ] || [ -z "$INPUT_FILE" ]; then
    printf 'mock-qwen: --json-file and --input-file are required\n' >&2
    exit 1
fi

# Use Python helper for centralized JSON serialization
PYTHON_HELPER="$(dirname "$0")/mock_qwen_json.py"

# Open the events FIFO for writing. This blocks until the tailer opens it for
# reading (fifo(7)); Kakoune launches the shim *before* the tailer, so the
# handshake completes once llm-tail-loop starts reading.
exec 4>"$JSON_FILE"

# session_start with the control-plane feature flag the tailer feature-detects.
python3 "$PYTHON_HELPER" emit session_start >&4

# Optional control-request round-trip: emit the request, then block until the
# harness approves it via :llm-approve (which appends a confirmation_response to
# --input-file). Only then do we continue streaming tokens.
if [ -n "$CONTROL_REQUEST" ]; then
    python3 "$PYTHON_HELPER" emit control_request "$CONTROL_REQUEST" >&4
    # Validate CONTROL_WAIT as integer to prevent arithmetic injection
    _raw_wait=${CONTROL_WAIT:-10}
    if printf '%s' "$_raw_wait" | grep -Eq '^[0-9]+$'; then
        control_wait=$_raw_wait
    else
        control_wait=10
    fi
    deadline=$(( $(printf '%s' "$(date +%s)" 2>/dev/null || echo 0) + control_wait ))
    while [ "$(date +%s 2>/dev/null || echo 0)" -lt "$deadline" ]; do
        # Use grep -F with a fixed pattern file to avoid shell interpolation
        if printf '%s\n' "\"request_id\":\"$CONTROL_REQUEST\"" | grep -F -f - "$INPUT_FILE" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
fi

# Stream the tokens as separate content_block_delta events so the tailer
# delivers each one to llm-append-delta as its own ghost-text node.
IFS=','
# Disable glob expansion so tokens containing *, ?, [...] are emitted verbatim.
set -f

for tok in $TOKENS; do
  python3 "$PYTHON_HELPER" emit content_delta "$tok" >&4
  if [ "$DELAY" != "0" ] && [ -n "$DELAY" ]; then
    sleep "$DELAY"
  fi
done

# Close the FIFO. EOF is the teardown signal: llm-tail-loop runs llm-stop,
# which kills Qwen's process group and removes the per-session temp dir.
exec 4>&-
