# Shared helper for LLM regression tests that exercise the detached tailer body
# (rc/tools/llm.kak, llm-tail-loop %sh{} body).
#
# Why standalone instead of `kak -p llm-tail-loop`: in these harness sessions an
# environment quirk prevents `-p` commands from executing against the session, so
# the detached body never starts and FIFO writes deadlock. Running the body
# directly (same code, launched via setsid) exercises identical logic. The body
# reads LLM_DIR / LLM_CLIENT / LLM_STOP_FILE env vars exactly as production
# passes them, so behaviour is equivalent.
#
# Each test calls:
#   llm_body_run      # launch the body under timeout
#   llm_body_open     # open the events FIFO via an O_RDWR fd (never blocks)
#   llm_body_feed ... # append JSONL events on that fd
#   llm_body_close    # close the fd
#   llm_body_wait     # wait briefly, then kill the body deterministically
#   llm_body_check PATTERN  # grep input.jsonl for PATTERN -> PASS/WARN
#   llm_body_calls PATTERN  # grep kak_calls.log for PATTERN -> PASS/WARN
#
# SAFETY against harness hangs: FIFO writes via O_RDWR fd (never block); body
# wrapped in timeout; body's inherited fds closed; body killed before exit.

LLM_BODY_DIR=$(mktemp -d /tmp/llm_body.XXXXXX)
mkdir -p "$LLM_BODY_DIR"
rm -f "$LLM_BODY_DIR"/events.jsonl "$LLM_BODY_DIR"/control.jsonl \
      "$LLM_BODY_DIR"/output.jsonl "$LLM_BODY_DIR"/input.jsonl \
      "$LLM_BODY_DIR"/stop "$LLM_BODY_DIR"/body.sh "$LLM_BODY_DIR"/body.out \
      "$LLM_BODY_DIR"/body.err "$LLM_BODY_DIR"/body.sh.env \
      "$LLM_BODY_DIR"/pending_control_requests.jsonl \
      "$LLM_BODY_DIR"/kak_calls.log
mkfifo "$LLM_BODY_DIR/events.jsonl" "$LLM_BODY_DIR/control.jsonl" \
       "$LLM_BODY_DIR/output.jsonl"
touch "$LLM_BODY_DIR/input.jsonl"

# Extract the tailer body (brace-aware) into a standalone script; kak_send is
# replaced with a logging stub so content_block_delta paths are observable.
python3 "$root/test/regression/llm/_llm_body_extract.py" \
    "$LLM_BODY_DIR/body.sh" "$root/rc/tools/llm.kak" \
    "$LLM_BODY_DIR/kak_calls.log"

# Env preamble the body needs (single-$ = shell env vars Kakoune does not expand).
{
  printf 'LLM_DIR=%q\n' "$LLM_BODY_DIR"
  printf 'LLM_KAK_CALLS_LOG=%q\n' "$LLM_BODY_DIR/kak_calls.log"
  printf 'LLM_CLIENT=%q\n' "${LLM_CLIENT:-client0}"
  printf 'LLM_STOP_FILE=%q\n' "$LLM_BODY_DIR/stop"
  printf 'kak_session=%q\n' "kak-tests"
  printf 'kak_opt_llm_dir=%q\n' "$LLM_BODY_DIR"
  printf 'kak_opt_llm_client=%q\n' "${LLM_CLIENT:-client0}"
  printf 'kak_opt_llm_stop_file=%q\n' "$LLM_BODY_DIR/stop"
  cat "$LLM_BODY_DIR/body.sh"
} > "$LLM_BODY_DIR/body.sh.env"

llm_body_run() {
  setsid bash "$LLM_BODY_DIR/body.sh.env" \
    >"$LLM_BODY_DIR/body.out" 2>"$LLM_BODY_DIR/body.err" </dev/null 3>&- 4>&- &
  sleep 0.5
}

# Non-blocking FIFO writer: open once, reuse. Never blocks even if no reader.
llm_body_open() { exec 9<>"$LLM_BODY_DIR/events.jsonl"; }
llm_body_feed() { printf '%s\n' "$1" >&9; }
llm_body_close() { exec 9>&-; }

# Wait briefly for the body to drain, then kill it deterministically.
llm_body_wait() { sleep 0.5; pkill -f 'body.sh.env' 2>/dev/null; sleep 0.2; }

# Assert that input.jsonl contains PATTERN (e.g. confirmation_response).
llm_body_check() {
  if grep -q "$1" "$LLM_BODY_DIR/input.jsonl" 2>/dev/null; then
    echo "llm-body-check: PASS ($1)"
  else
    echo "llm-body-check: WARN ($1)"
    echo "  input: $(cat "$LLM_BODY_DIR/input.jsonl" 2>/dev/null || echo EMPTY)"
    echo "  err:   $(head -3 "$LLM_BODY_DIR/body.err" 2>/dev/null || echo NONE)"
  fi
}

# Assert that kak_calls.log does NOT contain PATTERN (e.g. drift-stop emitted no
# delta). PASS when the pattern is absent.
llm_body_absent() {
  if grep -q "$1" "$LLM_BODY_DIR/kak_calls.log" 2>/dev/null; then
    echo "llm-body-absent: FAIL ($1 present)"
    echo "  calls: $(cat "$LLM_BODY_DIR/kak_calls.log" 2>/dev/null)"
  else
    echo "llm-body-absent: PASS ($1 absent)"
  fi
}

# Assert that kak_calls.log contains PATTERN (e.g. an llm-append-delta command).
llm_body_calls() {
  if grep -q "$1" "$LLM_BODY_DIR/kak_calls.log" 2>/dev/null; then
    echo "llm-body-calls: PASS ($1)"
  else
    echo "llm-body-calls: WARN ($1)"
    echo "  calls: $(cat "$LLM_BODY_DIR/kak_calls.log" 2>/dev/null || echo EMPTY)"
  fi
}

# ---------------------------------------------------------------------------
# N4 lifecycle helpers: exercise the real llm-session launcher (llm.kak) and
# llm-stop teardown body against stubs/mock-llm, asserting process-group kill
# and per-session temp-dir removal. Mirrors _llm_body.sh: bodies run standalone
# (setsid) with the exact env vars production passes; kak_send is stubbed to a
# calls log so emitted commands are observable without a live -p session.
# ---------------------------------------------------------------------------

LLM_SESSION_DIR=$(mktemp -d /tmp/llm_session.XXXXXX)
mkdir -p "$LLM_SESSION_DIR"
rm -f "$LLM_SESSION_DIR"/calls.log "$LLM_SESSION_DIR"/session.sh \
      "$LLM_SESSION_DIR"/stop.sh "$LLM_SESSION_DIR"/session.out \
      "$LLM_SESSION_DIR"/stop.out "$LLM_SESSION_DIR"/stop.err

# Extract the launcher + teardown bodies with kak_send stubbed to the calls log.
python3 "$root/test/regression/llm/_llm_body_extract.py" \
    "$LLM_SESSION_DIR/session.sh" "$root/rc/tools/llm.kak" \
    "$LLM_SESSION_DIR/calls.log" llm-session
python3 "$root/test/regression/llm/_llm_body_extract.py" \
    "$LLM_SESSION_DIR/stop.sh" "$root/rc/tools/llm.kak" \
    "$LLM_SESSION_DIR/calls.log" llm-stop

# Per-session env the launcher body reads (single-$ = shell vars Kakoune won't
# expand). Defaults mirror production; tests may override via env before calling.
LLM_CMD="${LLM_CMD:-mock-llm}"
LLM_CLIENT="${LLM_CLIENT:-client0}"
LLM_MODEL="${LLM_MODEL:-}"
LLM_ARGS="${LLM_ARGS:-}"
LLM_STUBS_DIR="$root/test/regression/llm/stubs"

# Recorded state (parsed from the calls log after llm_session_run).
llm_session_dir=""
llm_session_pid=""
llm_session_stop_file=""

# Launch the real llm-session body via setsid with the exact env vars production
# passes. kak_send is stubbed to the calls log (see _llm_body_extract.py), so
# emitted commands are observable without a live -p session.
llm_session_run() {
  setsid env \
    PATH="$LLM_STUBS_DIR:$PATH" \
    MOCK_LLM_STREAM=1 \
    kak_opt_llm_pid=0 \
    kak_opt_llm_cmd="$LLM_CMD" \
    kak_opt_llm_model="$LLM_MODEL" \
    kak_quoted_opt_llm_args="$LLM_ARGS" \
    kak_opt_llm_client="$LLM_CLIENT" \
    kak_client="$LLM_CLIENT" \
    kak_session="kak-tests" \
    LLM_KAK_CALLS_LOG="$LLM_SESSION_DIR/calls.log" \
    bash "$LLM_SESSION_DIR/session.sh" \
    >"$LLM_SESSION_DIR/session.out" 2>"$LLM_SESSION_DIR/session.err" </dev/null 3>&- 4>&- &
  sleep 0.6
}

# Parse recorded llm_dir / live mock-llm PID. The launcher records state via a
# bare printf (stdout), NOT kak_send, so we parse session.out rather than the
# calls log. setsid here forks rather than execs, so the recorded llm_pid points
# at a dead setsid PID; the live mock-llm carries its FIFO dir on its command
# line, so we derive the real PID (and thus its process group) from that.
llm_session_state() {
  llm_session_dir=$(grep -oE "set-option global llm_dir '[^']*'" "$LLM_SESSION_DIR/session.out" 2>/dev/null \
    | sed "s/.*'\([^']*\)'.*/\1/" | head -1)
  llm_session_stop_file="${llm_session_dir}/stop"
  # setsid's own cmdline also carries the dir, so match only the real mock-llm
  # process: its argv holds the full /mock-llm path (setsid passes bare "mock-llm").
  _llm_dir_re=$(printf '%s' "$llm_session_dir" | sed 's/[.[\*^$+?()]/\\&/g')
  llm_session_pid=$(pgrep -f "/mock-llm --json-file.*${_llm_dir_re}/events.jsonl" 2>/dev/null | head -1)
  if [ -z "$llm_session_pid" ]; then
    llm_session_pid=$(grep -oE "set-option global llm_pid [0-9]+" "$LLM_SESSION_DIR/session.out" 2>/dev/null \
      | awk '{print $4}' | head -1)
  fi
}

# Assert that the launcher's stdout (session.out) contains PATTERN.
llm_session_out() {
  if grep -q "$1" "$LLM_SESSION_DIR/session.out" 2>/dev/null; then
    echo "lifecycle-session: PASS ($1)"
  else
    echo "lifecycle-session: FAIL ($1)" >&2
    echo "  out: $(cat "$LLM_SESSION_DIR/session.out" 2>/dev/null || echo EMPTY)" >&2
    return 1
  fi
}

# Run the real llm-stop teardown body standalone, passing recorded pid/dir so it
# performs the process-group kill + temp-dir removal exactly as production does.
llm_stop_run() {
  if [ -z "$llm_session_pid" ] || [ -z "$llm_session_dir" ]; then
    echo "llm-stop: FAIL (no recorded pid/dir; pid=$llm_session_pid dir=$llm_session_dir)" >&2
    return 1
  fi
  setsid env \
    PATH="$LLM_STUBS_DIR:$PATH" \
    kak_opt_llm_pid="$llm_session_pid" \
    kak_opt_llm_dir="$llm_session_dir" \
    kak_opt_llm_stop_file="$llm_session_stop_file" \
    kak_session="kak-tests" \
    LLM_KAK_CALLS_LOG="$LLM_SESSION_DIR/calls.log" \
    bash "$LLM_SESSION_DIR/stop.sh" \
    >"$LLM_SESSION_DIR/stop.out" 2>"$LLM_SESSION_DIR/stop.err" </dev/null &
  sleep 0.3
}

# --- lifecycle assertions ---
llm_session_alive() { kill -0 "$llm_session_pid" 2>/dev/null; }
llm_session_dir_exists() { [ -d "$llm_session_dir" ]; }
llm_session_calls() {
  if grep -q "$1" "$LLM_SESSION_DIR/calls.log" 2>/dev/null; then
    echo "lifecycle-calls: PASS ($1)"
  else
    echo "lifecycle-calls: FAIL ($1)" >&2
    echo "  calls: $(cat "$LLM_SESSION_DIR/calls.log" 2>/dev/null || echo EMPTY)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Orphan cleanup (D7): if an assertion fails BEFORE llm_stop_run, the live
# mock-llm process group and /tmp/llm_session.* dir would otherwise leak.
# Reap them on EXIT. Keyed on LLM_SESSION_DIR so tailer-only tests (which never
# spawn a mock-llm writer) are unaffected — their pkill matches nothing and the
# transient empty dir is harmlessly removed.
# ---------------------------------------------------------------------------
_llm_session_cleanup() {
  if [ -n "${LLM_SESSION_DIR:-}" ]; then
    pkill -f "/mock-llm --json-file.*${LLM_SESSION_DIR}/events.jsonl" 2>/dev/null || true
    rm -rf "$LLM_SESSION_DIR" 2>/dev/null || true
  fi
}
trap _llm_session_cleanup EXIT
