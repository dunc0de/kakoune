# Shared helper for ghost regression tests that exercise the detached lifecycle
# bodies (rc/tools/ghost.kak: ghost-session launcher, ghost-stop teardown)
# standalone.
#
# Why standalone instead of `kak -p ghost-session`: the bodies' internal
# kak_send dispatches must be stubbed to a calls log, so each body is extracted
# and run in an isolated shell with the stub pre-applied (via
# _ghost_body_extract.py) -- a `kak -p ghost-session` against the harness
# session would leave the real kak_send in place, dispatching into that session
# with its emitted commands unobservable. The bodies run standalone (setsid)
# with the exact env vars production passes, exercising identical code. The
# launcher's detached tailer is the mock-ghost-tailer stub (a live process
# group that stays alive until killed) -- the same contract the lifecycle test
# needs from `python3 ghost_ws.py`.
#
# Each test calls:
#   ghost_session_run     # launch the real ghost-session body under setsid
#   ghost_session_state   # parse recorded dir/pid/session_id from the calls log
#   ghost_session_alive   # kill -0 on the live tailer PID
#   ghost_session_dir_exists
#   ghost_session_out PATTERN   # grep calls log for a recorded command
#   ghost_session_env PATTERN   # grep the tailer's captured env file
#   ghost_stop_run        # run the real ghost-stop body standalone
#   ghost_session_calls PATTERN # grep calls log (PASS/FAIL; alias of
#                                # ghost_session_out with a different PASS label)
#
# SAFETY against harness hangs: bodies run under setsid, are killed via their
# process group in ghost_stop_run, and the EXIT trap reaps any leaked mock
# tailer (matched by the stub path -- GHOST_DIR is env-only, never on the
# tailer's argv) + temp dir if an assertion fails before teardown.

GHOST_SESSION_DIR=$(mktemp -d /tmp/ghost_session.XXXXXX)
mkdir -p "$GHOST_SESSION_DIR"
rm -f "$GHOST_SESSION_DIR"/calls.log "$GHOST_SESSION_DIR"/session.sh \
      "$GHOST_SESSION_DIR"/stop.sh "$GHOST_SESSION_DIR"/session.out \
      "$GHOST_SESSION_DIR"/session.err "$GHOST_SESSION_DIR"/stop.out \
      "$GHOST_SESSION_DIR"/stop.err

# Extract the launcher + teardown bodies with kak_send stubbed to the calls log.
python3 "$root/test/regression/ghost/_ghost_body_extract.py" \
    "$GHOST_SESSION_DIR/session.sh" "$root/rc/tools/ghost.kak" \
    "$GHOST_SESSION_DIR/calls.log" ghost-session
python3 "$root/test/regression/ghost/_ghost_body_extract.py" \
    "$GHOST_SESSION_DIR/stop.sh" "$root/rc/tools/ghost.kak" \
    "$GHOST_SESSION_DIR/calls.log" ghost-stop

# Per-session env the launcher body reads (single-$ = shell vars Kakoune won't
# expand). Defaults mirror production; tests may override via env before calling.
GHOST_CMD="${GHOST_CMD:-mock-ghost-tailer}"
GHOST_CLIENT="${GHOST_CLIENT:-client0}"
GHOST_STUBS_DIR="$root/test/regression/ghost/stubs"
GHOST_WS_PY="${GHOST_WS_PY:-$GHOST_STUBS_DIR/mock-ghost-tailer}"
GHOST_WS_URL="${GHOST_WS_URL:-ws://localhost:9}"
GHOST_WS_TIMEOUT="${GHOST_WS_TIMEOUT:-0.5}"
GHOST_WS_CONTROL_POLL="${GHOST_WS_CONTROL_POLL:-0.1}"

# Kakoune exports option values to %sh{} bodies as kak_opt_<name> env vars; in
# these standalone bodies we provide the same contract (the ghost launcher
# relies on the runtime). PREPEND to the emitted wrapper so the values are set
# before the body's %sh{} subshell runs (appending would place them after the
# body has already run -- too late).
_ghost_preamble=$(cat <<EOF
kak_opt_ghost_pid=0
kak_opt_ghost_dir=""
kak_opt_ghost_ws_url="$GHOST_WS_URL"
kak_opt_ghost_ws_py="$GHOST_WS_PY"
kak_opt_ghost_ws_timeout="$GHOST_WS_TIMEOUT"
kak_opt_ghost_ws_control_poll="$GHOST_WS_CONTROL_POLL"
kak_opt_ghost_client="$GHOST_CLIENT"
kak_opt_ghost_session_name="${GHOST_SESSION_NAME:-kak-tests}"
EOF
)
printf '%s\n' "$_ghost_preamble" | cat - "$GHOST_SESSION_DIR/session.sh" > "${GHOST_SESSION_DIR}/session.sh.new" \
  && mv "${GHOST_SESSION_DIR}/session.sh.new" "$GHOST_SESSION_DIR/session.sh"

# Recorded state (parsed from the calls log after ghost_session_run). The
# ghost launcher records state via kak_send (which the stub appends to the
# calls log), so it lands in the calls log.
ghost_session_dir=""
ghost_session_pid=""
ghost_session_id=""

# Launch the real ghost-session body via setsid with the exact env vars
# production passes. kak_send is stubbed to the calls log (see
# _ghost_body_extract.py), so emitted commands are observable without a live
# session. GHOST_WS_PY points at the mock tailer: the body checks -f on it and
# hands its path to setsid, so the launcher runs its REAL code path end to end.
ghost_session_run() {
  setsid env \
    PATH="$GHOST_STUBS_DIR:$PATH" \
    GHOST_KAK_CALLS_LOG="$GHOST_SESSION_DIR/calls.log" \
    bash "$GHOST_SESSION_DIR/session.sh" \
    >"$GHOST_SESSION_DIR/session.out" 2>"$GHOST_SESSION_DIR/session.err" </dev/null 3>&- 4>&- &
  # Arbitrary settle: the body writes state to the calls log before it exits;
  # ghost_session_state parses that file (the sleep is not a race gate).
  sleep 1.2
}

# Parse recorded ghost_dir / live tailer PID / session_id. The launcher records
# ghost_pid as the setsid child ($!) -- the process-group leader, which is
# normally the mock's own PID (the launcher's subshell execs `setsid python3`,
# preserving the PID). We still prefer the mock's OWN pid from
# <dir>/.tailer.pid as the authoritative liveness target -- defensive, since
# pid == pgid after setsid+exec, so the process-group kill reaches it either
# way. pgrep -f can't be used for discovery: GHOST_DIR crosses the setsid
# boundary via env, so it is NOT on the mock's command line.
ghost_session_state() {
  ghost_session_dir=$(grep -oE "set-option global ghost_dir '[^']*'" "$GHOST_SESSION_DIR/calls.log" 2>/dev/null \
    | sed "s/.*'\([^']*\)'.*/\1/" | head -1)
  if [ -n "$ghost_session_dir" ] && [ -f "$ghost_session_dir/.tailer.pid" ]; then
    ghost_session_pid=$(head -1 "$ghost_session_dir/.tailer.pid" 2>/dev/null | tr -d '[:space:]')
  else
    ghost_session_pid=""
  fi
  if [ -z "$ghost_session_pid" ]; then
    ghost_session_pid=$(grep -oE "set-option global ghost_pid '[0-9]+'" "$GHOST_SESSION_DIR/calls.log" 2>/dev/null \
      | sed "s/.*'\([0-9]*\)'.*/\1/" | head -1)
  fi
  ghost_session_id=$(grep -oE "set-option global ghost_session_id '[^']*'" "$GHOST_SESSION_DIR/calls.log" 2>/dev/null \
    | sed "s/.*'\([^']*\)'.*/\1/" | head -1)
}

# Assert that the calls log contains PATTERN (e.g. a recorded set-option).
ghost_session_out() {
  if grep -q "$1" "$GHOST_SESSION_DIR/calls.log" 2>/dev/null; then
    echo "lifecycle-session: PASS ($1)"
  else
    echo "lifecycle-session: FAIL ($1)" >&2
    echo "  calls: $(cat "$GHOST_SESSION_DIR/calls.log" 2>/dev/null || echo EMPTY)" >&2
    return 1
  fi
}

# Assert that the tailer's captured env file contains PATTERN -- proves the
# GHOST_* vars crossed the setsid boundary (the export lesson).
ghost_session_env() {
  if [ -z "$ghost_session_dir" ] || [ ! -f "$ghost_session_dir/.tailer.env" ]; then
    echo "lifecycle-env: FAIL (no .tailer.env for dir=$ghost_session_dir)" >&2
    return 1
  fi
  if grep -q "$1" "$ghost_session_dir/.tailer.env" 2>/dev/null; then
    echo "lifecycle-env: PASS ($1)"
  else
    echo "lifecycle-env: FAIL ($1)" >&2
    echo "  env: $(cat "$ghost_session_dir/.tailer.env" 2>/dev/null || echo EMPTY)" >&2
    return 1
  fi
}

# Run the real ghost-stop teardown body standalone, passing recorded pid/dir so
# it performs the process-group kill + temp-dir removal exactly as production
# does.
ghost_stop_run() {
  if [ -z "$ghost_session_pid" ] || [ -z "$ghost_session_dir" ]; then
    echo "ghost-stop: FAIL (no recorded pid/dir; pid=$ghost_session_pid dir=$ghost_session_dir)" >&2
    return 1
  fi
  setsid env \
    PATH="$GHOST_STUBS_DIR:$PATH" \
    kak_opt_ghost_pid="$ghost_session_pid" \
    kak_opt_ghost_dir="$ghost_session_dir" \
    kak_opt_ghost_ws_py="$GHOST_WS_PY" \
    GHOST_KAK_CALLS_LOG="$GHOST_SESSION_DIR/calls.log" \
    bash "$GHOST_SESSION_DIR/stop.sh" \
    >"$GHOST_SESSION_DIR/stop.out" 2>"$GHOST_SESSION_DIR/stop.err" </dev/null &
  # Arbitrary settle: the stop body kills the process group and removes the
  # scratch dir synchronously before it exits.
  sleep 1.0
}

# --- lifecycle assertions ---
ghost_session_alive() { kill -0 "$ghost_session_pid" 2>/dev/null; }
ghost_session_dir_exists() { [ -d "$ghost_session_dir" ]; }
ghost_session_calls() {
  if grep -q "$1" "$GHOST_SESSION_DIR/calls.log" 2>/dev/null; then
    echo "lifecycle-calls: PASS ($1)"
  else
    echo "lifecycle-calls: FAIL ($1)" >&2
    echo "  calls: $(cat "$GHOST_SESSION_DIR/calls.log" 2>/dev/null || echo EMPTY)" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# ghost_session_out and ghost_session_calls both grep the calls log; kept as
# two functions so call sites can use scenario-specific PASS labels
# (lifecycle-session vs lifecycle-calls).
#
# ---------------------------------------------------------------------------
# Orphan cleanup: if an assertion fails BEFORE ghost_stop_run, the live mock
# tailer process group and the /tmp/ghost_session.* dir would otherwise leak.
# Reap them on EXIT. This file is sourced only by lifecycle tests.
# ---------------------------------------------------------------------------
_ghost_session_cleanup() {
  if [ -n "${GHOST_SESSION_DIR:-}" ]; then
    # Match by the stub path: GHOST_DIR crosses the setsid boundary via env,
    # so the tailer's argv is `python3 <GHOST_WS_PY>` with no dir argument --
    # a pattern anchored on GHOST_SESSION_DIR can never match it.
    _ws_py_re=$(printf '%s' "$GHOST_WS_PY" | sed 's/[.[\*^$+?()]/\\&/g')
    pkill -f "$_ws_py_re" 2>/dev/null || true
    rm -rf "$GHOST_SESSION_DIR" 2>/dev/null || true
  fi
}
trap _ghost_session_cleanup EXIT
