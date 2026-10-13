#!/bin/bash
# tmux real-user test: llm.kak accept scenario
# Drives :llm-session, streams tokens via mock-qwen.sh, accepts ghost text,
# and verifies the buffer persisted to disk.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$PROJECT_ROOT/skills/tmux-real-user-testing/scripts/tmux-real-user-log.sh"
MOCK_SHIM="$PROJECT_ROOT/test/e2e/mock-qwen.sh"
LLM_KAK="$PROJECT_ROOT/rc/tools/llm.kak"
TARGET="$PROJECT_ROOT/tmp/llm-accept-target.txt"

TS=$(date +%Y%m%d-%H%M%S)
SCENARIO="llm-accept"
OUT="$PROJECT_ROOT/tmp/${SCENARIO}-tmux-$TS"
SESSION="${SCENARIO}-$TS"
CURRENT_STEP="setup"

mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# write_report <RESULT>
# Emit report.md. Called on both PASS and FAIL so a structured, evidence-linked
# artifact always exists — including when the run aborts early under set -e.
# ---------------------------------------------------------------------------
write_report() {
    local result="$1"
    local _date _session _outdir _target _scenario
    _date="$(date '+%Y-%m-%d %H:%M:%S')"
    _session="${SESSION}"
    _outdir="${OUT}"
    _target="${TARGET}"
    _scenario="${SCENARIO}"
    # Quoted heredoc so nothing inside executes as shell (backticks, $(), etc.
    # are literal). Dynamic values are injected via sed placeholders below.
    cat > "${_outdir}/report.md" <<'EOF'
# tmux Real-User Test Report: @@SCENARIO@@

- **Date:** @@DATE@@
- **tmux session:** @@SESSION@@
- **Kakoune binary:** @@PROJECT_ROOT@@/src/kak
- **Workspace:** @@PROJECT_ROOT@@
- **Target file:** @@TARGET@@

## Scenario scope

Test the `:llm-accept` flow:
1. Load target file with baseline content
2. Source llm.kak wired to mock-qwen.sh
3. Run `:llm-session` to start token streaming
4. Wait for ghost text (draft active)
5. Run `:llm-accept` to commit ghost text
6. Write and quit
7. Verify buffer persisted

## Steps tested

| Step | Action | Log section |
|------|--------|-------------|
| 1 | source llm.kak (defines commands) | 01 source llm.kak |
| 2 | require-module llm (declares options) | 02 require-module llm |
| 3 | Set llm_args (tokens + delay) | 03 set llm_args |
| 4 | Set llm_cmd to mock shim | 04 set llm_cmd to mock shim |
| 5 | Launch :llm-session | 05 llm-session launched |
| 6 | Wait for "llm session started" | 06 llm session started |
| 7 | Wait for draft active (ghost text) | 07 draft active, ghost text on screen |
| 8 | Execute :llm-accept | 08 llm-accept executed |
| 9 | Verify Normal mode returned | 09 back to normal after accept |
| 10 | Write and quit | — |

## Result

**@@RESULT@@**

## Key observations

- Log section `05 llm session started` shows the session launch confirmation.
- Log section `06 draft active, ghost text on screen` shows ghost text rendered
  in the TUI after token streaming completed.
- Log section `07 llm-accept executed` shows Kakoune returned to Normal mode
  after accepting the draft.

## Artifacts

- **Primary log:** `tmux-readable-full.log`
- Final capture: `tmux-final-capture.log`
- Target file: @@TARGET@@

## Side effects

- Target file @@TARGET@@ was modified on disk (ghost text persisted).
- Per-session temp dir created under `/tmp/kak-llm.*` by `:llm-session`.
EOF
    sed -i \
        -e "s|@@SCENARIO@@|${_scenario}|g" \
        -e "s|@@DATE@@|${_date}|g" \
        -e "s|@@SESSION@@|${_session}|g" \
        -e "s|@@PROJECT_ROOT@@|${PROJECT_ROOT}|g" \
        -e "s|@@TARGET@@|${_target}|g" \
        -e "s|@@RESULT@@|${result}|g" \
        "${_outdir}/report.md"
}

# ---------------------------------------------------------------------------
# cleanup — always kill the tmux session; on an aborted (non-zero) exit, write a
# FAIL report so the narrative artifact survives failure paths (e.g. a wait-for
# timeout under set -e). Preserves the exit code.
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [ -n "${SESSION:-}" ] && tmux has-session -t "$SESSION" 2>/dev/null; then
        tmux kill-session -t "$SESSION" 2>/dev/null || true
    fi
    if [ "$rc" -ne 0 ] && [ -n "${OUT:-}" ] && [ ! -f "$OUT/report.md" ]; then
        write_report "FAIL (aborted at step: $CURRENT_STEP)" || true
    fi
    return "$rc"
}
trap cleanup EXIT INT TERM

# Create target file with baseline content
printf 'hello\nworld\n' > "$TARGET"

echo "=== Starting tmux real-user test: $SCENARIO ==="
echo "Session: $SESSION"
echo "Output dir: $OUT"
echo "Target file: $TARGET"

# Start Kakoune in a large tmux viewport (workdir is PROJECT_ROOT; helper
# computes the timestamped outdir under $PROJECT_ROOT/tmp/).
# Use `kak -n` to skip sourcing kakrc on startup, preventing the KakBegin hook
# from auto-sourcing llm.kak before the test's explicit `source $LLM_KAK`.
CURRENT_STEP="start"
eval "$(bash "$HELPER" start "$SCENARIO" "$PROJECT_ROOT" "$PROJECT_ROOT/src/kak -n" "$TARGET")"
echo "SESSION=$SESSION OUTDIR=$OUTDIR LOG=$LOG"

# Wait for Kakoune to be ready (Normal mode status line shows "1 sel")
CURRENT_STEP="wait-for Normal ready"
bash "$HELPER" wait-for "$SESSION" "$OUTDIR" "1 sel" 30 1 100

# Load the module first so its options (llm_cmd, llm_args, ...) are declared.
# `source llm.kak` runs the top-level `define-command` lines (llm-session etc.)
# but does NOT declare options (they live inside provide-module).
# `require-module llm` then declares the options. Both are needed because `-n`
# skips the KakBegin hook that would otherwise auto-run require-module.
CURRENT_STEP="source llm.kak"
bash "$HELPER" kak-cmd "$SESSION" "source $LLM_KAK"
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "01 source llm.kak"

CURRENT_STEP="require-module llm"
bash "$HELPER" kak-cmd "$SESSION" "require-module llm"
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "02 require-module llm"

# 1. Set llm_args (tokens + delay)
CURRENT_STEP="set llm_args"
bash "$HELPER" kak-cmd "$SESSION" "set-option global llm_args --tokens Hello world --delay 0.05"
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "03 set llm_args"

# 2. Point llm_cmd at the mock shim
CURRENT_STEP="set llm_cmd to mock shim"
bash "$HELPER" kak-cmd "$SESSION" "set-option global llm_cmd $MOCK_SHIM"
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "04 set llm_cmd to mock shim"

# 3. Start the LLM session (pass empty prompt arg to avoid Kakoune prompt mode)
CURRENT_STEP="llm-session launched"
bash "$HELPER" kak-cmd "$SESSION" 'llm-session ""'
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "05 llm-session launched"

# 4. Wait for "llm session started"
CURRENT_STEP="llm session started"
bash "$HELPER" wait-for "$SESSION" "$OUTDIR" "llm session started" 30 1 100
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "06 llm session started"

# 5. Wait for ghost text to appear (draft active). The mock shim emits tokens
#    "Hello" and "world", so the visible ghost text is "Helloworld".
#
# TODO(FIXME): this wait is exactly where the scenario has failed — "Helloworld"
# never appears even though the tailer launches (.dbg shows guard passed + body
# started). Budget = 30 x 2s = 60s. If it times out, the root cause is upstream
# in llm.kak (deltas never reach llm-append-delta); do NOT silently raise the
# budget — instead inspect <dir>/.dbg, .llm_tailer.stderr, and events.jsonl.
CURRENT_STEP="draft active"
bash "$HELPER" wait-for "$SESSION" "$OUTDIR" "Helloworld" 30 2 200
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "07 draft active, ghost text on screen"

# Intermediate assertion: ghost text must actually be visible BEFORE accepting.
# wait-for leaves the matching pane in current-pane.txt, so reuse it.
if ! grep -q "Helloworld" "$OUTDIR/current-pane.txt"; then
    echo "[FAIL] ghost text 'Helloworld' not visible before :llm-accept" >&2
    cat "$OUTDIR/current-pane.txt" >&2 || true
    exit 1
fi

# 6. Accept the ghost text
CURRENT_STEP="llm-accept executed"
bash "$HELPER" kak-cmd "$SESSION" "llm-accept"
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "08 llm-accept executed"

# Intermediate assertion: Kakoune must return to Normal mode after accept.
CURRENT_STEP="verify normal mode returned"
bash "$HELPER" wait-for "$SESSION" "$OUTDIR" -- "-- Normal --" 20 1 100
bash "$HELPER" snapshot "$SESSION" "$OUTDIR" "09 back to normal after accept"

# 7. Write and quit
CURRENT_STEP="write and quit"
bash "$HELPER" kak-cmd "$SESSION" "write!"
bash "$HELPER" kak-cmd "$SESSION" "quit!"

# 8. Wait for Kakoune to exit
for i in $(seq 1 30); do
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        break
    fi
    sleep 1
done

# 9. Final capture
tmux capture-pane -t "$SESSION" -p -S -10000 > "$OUT/tmux-final-capture.log" 2>/dev/null || true
{
    printf '\n===== final capture before cleanup =====\n'
    cat "$OUT/tmux-final-capture.log" 2>/dev/null || echo "(no final capture)"
} >> "$LOG"

# 10. Verify the target file
echo ""
echo "=== Verifying target file ==="
EXPECTED="Helloworldhello
world
"
ACTUAL="$(cat "$TARGET")"
echo "Expected:"
printf '%s' "$EXPECTED"
echo "---"
echo "Actual:"
printf '%s' "$ACTUAL"
echo "---"

if [ "$ACTUAL" = "$EXPECTED" ]; then
    RESULT="PASS"
else
    RESULT="FAIL"
fi

# 11. Write report (structured artifact, evidence-linked)
write_report "$RESULT"

echo ""
echo "=== Result: $RESULT ==="
echo "Logs saved to: $OUT"
echo "Primary log: $OUT/tmux-readable-full.log"

if [ "$RESULT" = "PASS" ]; then
    exit 0
else
    echo "Expected content: $EXPECTED"
    echo "Actual content: $ACTUAL"
    exit 1
fi
