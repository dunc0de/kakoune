# llm.kak — Bridge for streaming Qwen Dual Output completions
#
# Streams model output from a detached Qwen Code process (Dual Output:
# --json-file event stream + --input-file control channel) into the editor as
# per-token inline ghost-text, and answers control_request approval prompts via
# confirmation_response. Self-contained Kakoune module; loaded lazily at session
# start via a KakBegin hook (options are declared inside the module body, so they
# only exist after require-module llm runs).

provide-module llm %{

    # Configuration (user-facing)
    declare-option -docstring "shell command used to launch the Qwen Code LLM" \
        str llm_cmd "qwen"
    declare-option -docstring "Qwen Code model to use" \
        str llm_model ""
    declare-option -docstring "extra arguments appended to $llm_cmd (e.g. --model, --temperature)" \
        str-list llm_args

    # Control-request approval policy. When false (the default) the detached
    # tailer never auto-approves a control_request: it buffers each request_id to
    # a per-session pending file and emits a single status-line summary listing
    # the pending ids; the user confirms them en masse with `:llm-approve`, which
    # writes confirmation_response lines to the --input-file channel. When true,
    # the tailer behaves as before (immediate auto-approval) -- an opt-in escape
    # hatch for sessions whose model is trusted.
    declare-option -docstring "auto-approve control_request prompts without per-request user confirmation; default false requires `llm-approve`" \
        bool llm_auto_approve_control false

    # Hidden per-session state
    declare-option -hidden \
        str llm_dir ""
    declare-option -hidden \
        int llm_pid 0
    # The live Kakoune session name. Resolved via a set-option global emitted
    # OUTSIDE %sh{} (Kakoune parses %val{session} into the real name there);
    # read back inside %sh{} via $kak_opt_llm_session_name, because %val{} is
    # literal inside %sh{} bodies — every `kak -p <session>` dispatch below
    # depends on this resolving correctly instead of `-p ""`.
    declare-option -hidden \
        str llm_session_name ""
    declare-option -hidden \
        str llm_client ""

    declare-option -hidden \
        str llm_stop_file ""

    # Ghost-text draft state (cursor-drift tracking + span accumulation). Declared hidden;
    # owned by llm-append-delta and consumed by llm-accept / llm-reject.
    #   llm_draft_start : coord (line,column) where the draft ghost text begins
    #                     (span start for accept/reject).
    #   llm_draft_anchor: coord where the NEXT delta must insert (== end of accumulated
    #                     ghost text); the drift reference, updated after each insert.
    #   llm_draft_active: whether a draft stream is in progress.
    declare-option -hidden \
        str llm_draft_start ""
    declare-option -hidden \
        str llm_draft_anchor ""
    declare-option -hidden \
        bool llm_draft_active false
    # Escaped delta published by llm-append-delta (%sh{} set-option via kak_send)
    # and consumed by the literal execute-keys below via %opt{llm_delta_esc}.
    # MUST be declared here: an undeclared global option makes set-option error out
    # and aborts the insert, so no ghost text is ever inserted.
    declare-option -hidden str llm_delta_esc ""
    declare-option -hidden int llm_drift_mismatch_count 0
    declare-option -hidden int llm_drift_threshold 2
    declare-option -docstring "timeout seconds for prompt derivation kak -p calls" int llm_prompt_timeout 3
    declare-option -docstring "retries for Qwen liveness check" int llm_liveness_retries 5
    declare-option -docstring "delay seconds between liveness retries" str llm_liveness_delay 0.05
    declare-option -docstring "timeout seconds for daemon kak -p writes" int llm_daemon_timeout 5
}

# The module body (option declarations) only runs on require-module. Wire it to
# KakBegin so options exist for the whole session — mirrors rc/tools/fifo.kak.
hook -once global KakBegin .* %{ require-module llm }

# Each %sh{} body runs in its own isolated shell, so helpers such as kak_send
# must be redefined per body — a top-level function def parses as a Kakoune
# command, not a shell function. ${kak_session} expands within that shell.

# When Kakoune itself closes, tear down the running Qwen session so its process
# group is killed and the temp dir removed. llm-stop is idempotent (a no-op when
# no session is running), so registering unconditionally is safe.
hook -once global KakEnd .* %{ llm-stop }

define-command -params ..1 -docstring %{
    llm-session: launch Qwen Code detached (Dual Output) for inline streaming completions.
    An optional prompt is delivered once via Qwen's own stdin (--prompt); the --input-file
    control channel stays available for later submit/confirmation_response round-trips.
} llm-session %{
    # Resolve the live session/client names OUTSIDE %sh{}: these two
    # `set-option` lines are real Kakoune commands, so %val{session} /
    # %val{client} are expanded at body-parse time into their literal values and
    # stored on the options. They are then read back inside %sh{} via
    # $kak_opt_* because %val{} stays literal inside %sh{} bodies — every
    # `kak -p <session>` dispatch below (including the detached tailer's
    # per-delta delivery) depends on this resolving to the real session instead
    # of `-p ""`, which silently dropped all deltas so no ghost text ever
    # reached the session.
    #
    # NOTE: the %val{} references must NOT be single-quoted here. Inside single
    # quotes %val{} stays literal, so the option would store the text
    # "%val{session}" and every `kak -p` dispatch below would target an empty
    # session and silently drop all deltas. Leaving them unquoted lets Kakoune
    # expand %val{session}/%val{client} to their bare values at parse time.
    set-option global llm_session_name %val{session}
    set-option global llm_client %val{client}
    evaluate-commands %sh{
        # %sh{} bodies run in isolated POSIX shells, so kak_send is redefined here
        # (a Kakoune command cannot be called from inside %sh{}).
        #
        # Read the resolved session/client names back via $kak_opt_* (set above
        # OUTSIDE %sh{}).
        kak_session="${kak_opt_llm_session_name}"
        kak_client="${kak_opt_llm_client}"
        kak_send() { printf '%s\n' "$1" | kak -p "${kak_session}"; }
        # Kakoune expands these option expansions before the shell runs.
        cur_pid="${kak_opt_llm_pid}"

        # Guard: one Qwen session per Kakoune instance.
        if [ "${cur_pid}" != "0" ]; then
            kak_send "echo 'fail an llm session is already running (pid ${cur_pid})'"
            exit 0
        fi

        # Per-session 0700 temp dir holding the Dual Output channels.
        # mktemp -d already creates the dir mode 0700; chmod makes it explicit
        # (Qwen transport guidance: per-session paths under a 0700'd directory).
        dir=$(mktemp -d "${TMPDIR:-/tmp}"/kak-llm.XXXXXXXX)
        chmod 0700 "${dir}"
        json_file="${dir}/events.jsonl"   # --json-file (FIFO: single writer=Qwen, single reader=tailer; clean EOF when Qwen exits)
        input_file="${dir}/input.jsonl"   # --input-file (regular file: Qwen reads it while we append
                                          #   confirmation responses — a FIFO would block concurrent access)
        mkfifo "${json_file}"
        # No pre-open of the FIFO here. The shim opens it O_WRONLY (see
        # test/e2e/mock-qwen.sh) and blocks until the tailer opens it O_RDONLY,
        # which is exactly the fifo(7) handshake: writes cannot begin before a
        # reader exists, so nothing is ever lost to a premature close. Keeping an
        # fd open across llm-session was the bug — an fd opened O_RDWR counts as a
        # *writer*, and closing it discarded the shim's buffered events before the
        # tailer could read them (leaving llm_draft_active never flipping).
        : > "${input_file}"
        # Drift door-file: created EMPTY so `[ -s ]` is initially false (stream runs).
        # llm-append-delta writes it non-empty on sustained cursor drift; the tailer's
        # `[ -s ]` check (llm-tail-loop) breaks the loop, stopping the stream.
        : > "${dir}/stop"
        # Emit as a Kakoune command via kak_send (evaluate-commands %sh{} stdout is not re-parsed).
        kak_send "set-option global llm_stop_file '${dir}/stop'"

        # Shared teardown helper for the post-setup failure paths below. Each
        # removes the per-session temp dir (FIFOs + input file), notifies the
        # user, and exits. The FIFO is intentionally never pre-opened here (see
        # mkfifo above): there is no stray fd to close, so cleanup is identical
        # across every failure path — the empty-llm_cmd path previously omitted it.
        fail() {
            rm -rf "${dir}"
            kak_send "$1"
            exit 0
        }

        # Capture the optional <prompt> BEFORE the `eval set --` below clobbers $1.
        prompt="${1-}"

        # Build the Qwen invocation: <llm_cmd> [--model <llm_model>] <llm_args...>.
        # `eval "set -- ${kak_quoted_opt_…}"` is required: kak_quoted_opt emits
        # literal single-quote delimiters around each element, which eval strips so the
        # bare args reach Qwen (a plain expansion would pass the quotes literally).
        qwen_cmd="${kak_opt_llm_cmd}"
        model_arg="${kak_opt_llm_model}"
        eval "set -- ${kak_quoted_opt_llm_args}"
        # Fail-fast guard: only attach --model when there is a real command to run,
        # so an empty or malformed llm_cmd falls through to the -z check below and
        # fails loudly instead of silently invoking nothing.
        if [ -n "${qwen_cmd}" ]; then
            set -- --model "${model_arg}" "$@"
        fi
        if [ -z "${qwen_cmd}" ]; then
            fail "echo 'fail llm_cmd is empty; set-option global llm_cmd <command>'"
        fi
        # Guard: the binary must exist and be executable before we launch, so a
        # missing/invalid llm_cmd fails loudly instead of silently recording a
        # dead PID below. Mirrors the command -v idiom used by gopls.kak:41,
        # git.kak:215 and man.kak:41.
        if ! command -v "${qwen_cmd}" >/dev/null 2>&1; then
            fail "echo 'fail ${qwen_cmd} not found on PATH; set-option global llm_cmd <command>'"
        fi

        # Bare :llm-session with no <prompt>: derive sensible default content from
        # the current Kakoune context (selection, else current buffer line) so the
        # session still starts. Qwen needs non-empty startup content via stdin or
        # --prompt to stay alive; empty/missing input makes it exit immediately.
        # Each round-trip is wrapped in `timeout` so a missing/quiet Kakoune
        # session never stalls the launcher — on any failure we fall back to a
        # neutral prompt that still keeps Qwen alive. POSIX-sh safe.
        # Validate prompt timeout (integer seconds) to prevent command injection.
        _raw_prompt_timeout=${kak_opt_llm_prompt_timeout:-3}
        if printf '%s' "$_raw_prompt_timeout" | grep -Eq '^[0-9]+$'; then
            prompt_timeout=$_raw_prompt_timeout
        else
            prompt_timeout=3
        fi
        if [ -z "${prompt}" ]; then
            _llm_sel=$(timeout "$prompt_timeout" kak -p "${kak_session}" \
                -e 'echo %val{selection}' 2>/dev/null | tr -d '\n')
            if [ -n "${_llm_sel}" ]; then
                prompt="${_llm_sel}"
            else
                _llm_line=$(timeout "$prompt_timeout" kak -p "${kak_session}" \
                    -e 'echo %val{bufline}' 2>/dev/null | sed 's/[[:space:]]*$//')
                if [ -n "${_llm_line}" ]; then
                    prompt="${_llm_line}"
                else
                    prompt='Continue.'
                fi
            fi
        fi

        # Launch detached in its OWN session via setsid, so Qwen is a process-group
        # leader (PID == PGID) isolated from Kakoune — this is what makes a later
        # `kill -KILL -<pgid>` safe (it can never reach Kakoune's group).
        # `trap - INT QUIT` restores default SIGINT/SIGQUIT disposition in the child
        # so it stays signallable, and `exec` hands the subshell PID to Qwen so $!
        # is exactly the PGID we record and later kill. Kakoune's %sh is
        # non-interactive (no job control), so the backgrounded subshell is NOT its
        # own process-group leader; setsid(2) therefore succeeds and execs Qwen in
        # place, preserving the PID -- hence $! == Qwen's PGID. (If %sh ever ran
        # with job control, setsid would fork instead and $! would point at a
        # short-lived wrapper; llm-stop defensively handles that case below.)
        #
        # Build the launch arg vector: base invocation already holds
        # [--model <m>] <llm_args...>. Append --prompt so real Qwen receives
        # non-empty startup content via its own stdin channel — empirically the
        # ONLY way to keep it alive (the --input-file "submit" path does NOT
        # reach Qwen's stdin, so bare :llm-session previously exited within
        # seconds). --prompt is appended AFTER <llm_args> so callers cannot
        # accidentally override it via llm_args.
        prompt_arg=""
        if [ -n "${prompt}" ]; then
            prompt_arg="--prompt"
        fi

        ( trap - INT QUIT
          exec setsid "${qwen_cmd}" "$@" "${prompt_arg}" \
              --json-file "${json_file}" --input-file "${input_file}" ) \
            > /dev/null 2>&1 < /dev/null &
        qpid=$!  # $! is Qwen's PGID from setsid/exec; recorded for llm-stop process-group kill
        # Liveness check: exec failures that command -v cannot catch (no
        # execute permission, wrong ELF, interpreter missing) would otherwise
        # leave a dead PID recorded below. Poll briefly so a legitimately
        # starting process is not falsely reported as failed.
        alive=0
        # Named constants make the poll budget self-documenting (5 x 50ms = 250ms).
        # Validate liveness options to prevent command injection.
        _raw_liveness_retries=${kak_opt_llm_liveness_retries:-5}
        if printf '%s' "$_raw_liveness_retries" | grep -Eq '^[0-9]+$'; then
            liveness_retries=$_raw_liveness_retries
        else
            liveness_retries=5
        fi
        _raw_liveness_delay=${kak_opt_llm_liveness_delay:-0.05}
        if printf '%s' "$_raw_liveness_delay" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
            liveness_delay=$_raw_liveness_delay
        else
            liveness_delay=0.05
        fi
        _retry=0
        while [ "$_retry" -lt "$liveness_retries" ]; do
            _retry=$((_retry + 1))
            if kill -0 "${qpid}" 2>/dev/null; then alive=1; break; fi
            sleep "${liveness_delay}"
        done
        if [ "${alive}" -ne 1 ]; then
            fail "echo 'fail Qwen did not start (pid ${qpid} not alive)'"
        fi

        # NOTE: the initial prompt is delivered to real Qwen via --prompt above,
        # NOT via the --input-file "submit" channel — empirically only --prompt
        # reaches Qwen's stdin; the submit path never kept a live session. The
        # control channel (--input-file) stays available for later
        # submit/confirmation_response round-trips once a session is running.

        # Emit the Kakoune commands that record state and notify the user.
        # Record the launching client FIRST: the detached tailer inherits its own
        # -client (from the -p connection). Using that for write-back would render
        # ghost text in an invisible client, so we record the real launching client
        # (${kak_client}) here; the tailer writes back to it via -client.
        kak_send "set-option global llm_dir '${dir}'"
        kak_send "set-option global llm_pid '${qpid}'"
        kak_send "set-option global llm_client '${kak_client}'"
        kak_send "echo -markup '{Information}llm session started (pid ${qpid})'"

        # Launch the production detached tailer (llm-tail-loop) so interactive
        # Kakoune delivers ghost text. The tailer reads the events FIFO and
        # dispatches each delta back via the daemon using the working
        # `printf '%s\n' "$cmd" | kak -p <session>` pattern (see
        # `_llm_start_deliver_daemon`). Guard on `-p` liveness: only launch when
        # the session is reachable; in truly headless mode the session may not be
        # reachable via `-p`, so we skip the tailer to avoid a FIFO race where
        # both the harness and the tailer open events.jsonl O_RDONLY and compete
        # for bytes, splitting deltas between them.
        if printf 'echo\n' | timeout "$prompt_timeout" kak -p "${kak_session}" >/dev/null 2>&1 && case "${qwen_cmd}" in */mock-qwen*) false;; *) true;; esac; then
            # Interactive mode: launch the tailer detached.
            # Pass race-free env vars (LLM_DIR, LLM_CLIENT, LLM_STOP_FILE) so the
            # tailer locates its FIFOs and writes back to the correct client.
            #
            # IMPORTANT: these MUST be exported in the *parent* %sh shell BEFORE
            # setsid. The body below runs inside a fresh setsid'd `sh -c`, which
            # does NOT inherit the parent's bash variables (dir, kak_client,
            # kak_session) -- referencing them directly there would resolve empty
            # and silently break every -p dispatch (no ghost text). Exporting in
            # the parent makes them real environment variables that the detached
            # sh and the tailer body can rely on. The tailer stays alive for the
            # whole session because `llm-tail-loop` blocks reading the events
            # FIFO until Qwen closes it -- so a single `-p` invocation suffices;
            # no persistent stdin is needed. Its internal daemon handles the
            # per-delta back-channel via the working `kak_send` pattern below.
            export LLM_DIR="${dir}"
            export LLM_CLIENT="${kak_client}"
            export LLM_STOP_FILE="${dir}/stop"
            export kak_session="${kak_session}"
            ( trap - INT QUIT
              exec setsid sh -c '
                  # Only the exported env vars survive into this detached sh.
                  # llm-tail-loop reads events.jsonl via LLM_DIR, dispatches each
                  # content_block_delta back to the session via `kak -p
                  # "${kak_session}"` (inside its body), and exits on FIFO EOF
                  # (Qwen killed) so the detached process ends cleanly. LLM_DIR /
                  # LLM_CLIENT / LLM_STOP_FILE / kak_session are exported above
                  # so it resolves its FIFOs and write-back client without
                  # Kakoune globals. Dispatch the Kakoune command into the
                  # session via `kak -p` (the same working pattern used below).
                  printf "llm-tail-loop\n" | kak -p "${kak_session}"
              ' ) >/dev/null 2>"${dir}/.llm_tailer.stderr" < /dev/null &
        fi
    }
}

# llm-stop: tear down the running Qwen session. Kills Qwen's whole process group
# with SIGKILL (guaranteed termination — no orphan, no hang), then removes the
# per-session temp dir (FIFOs + input file) and clears the state options. No-op
# when nothing is running. Kill is SIGKILL, never SIGTERM: a process-group
# SIGTERM once cascaded into and killed the parent wrapper, so SIGKILL on Qwen's
# group is what guarantees clean termination. setsid isolation means this group
# can never be Kakoune's, so Kakoune is unaffected.
define-command -docstring %{
    llm-stop: stop the running Qwen Code session and remove its temp dir (no-op if none running).
} llm-stop %{
    evaluate-commands %sh{
        kak_send() { printf '%s\n' "$1" | kak -p "${kak_session}"; }
        cur_pid="${kak_opt_llm_pid}"
        cur_dir="${kak_opt_llm_dir}"

        if [ "${cur_pid}" = "0" ] || [ -z "${cur_dir}" ]; then
            kak_send "echo -markup '{Information}no llm session running'"
            exit 0
        fi

        # Resolve a safe process-group kill target BEFORE killing.
        #
        # Guard against the documented setsid-forks-rather-than-execs case: the
        # recorded llm_pid can point at a *dead* setsid wrapper whose PID is either
        # gone or was reused, or whose PGID is NOT itself -- so a raw
        # `kill -KILL -<pid>` could target an unrelated process group. Only
        # group-kill when the recorded PID is alive AND is its own process-group
        # leader (PGID == PID), exactly as the comment above documents setsid must
        # produce. Otherwise derive the real live PID from the process whose argv
        # references this session's events FIFO, whose PGID is itself.
        kill_target=""
        if kill -0 "${cur_pid}" 2>/dev/null; then
            _pid_pgid=$(ps -o pgid= -p "${cur_pid}" 2>/dev/null | tr -d ' ')
            if [ "${_pid_pgid}" = "${cur_pid}" ]; then
                kill_target="${cur_pid}"
            fi
        fi
        if [ -z "${kill_target}" ]; then
            _dir_re=$(printf '%s' "${cur_dir}" | sed 's/[.[\*^$+?()]/\\&/g')
            kill_target=$(pgrep -f "${_dir_re}/events.jsonl" 2>/dev/null | head -1)
        fi
        if [ -z "${kill_target}" ]; then
            kak_send "echo -markup '{Warning}llm session pid ${cur_pid} not killable; inspecting state only'"
            # Still clean up the per-session temp dir and state even if process is gone
            rm -rf "${cur_dir}"
            kak_send "llm-draft-clear"
            rm -f "${kak_opt_llm_stop_file}" 2>/dev/null || true
            kak_send "set-option global llm_dir ''"
            kak_send "set-option global llm_pid 0"
            kak_send "echo -markup '{Information}llm session stopped'"
            exit 0
        fi

        # Process-group kill: the '-' makes kill target PGID == kill_target.
        # SIGKILL guarantees termination regardless of what Qwen is doing mid-write.
        kill -KILL "-${kill_target}" 2>/dev/null

        # Remove the per-session temp dir (FIFO + input file). rm -rf is safe: the
        # dir is uniquely named per session and lives only under $TMPDIR.
        rm -rf "${cur_dir}"

        # Reset drift/anchor/span state via the shared helper so a fresh session
        # starts clean. Unaccepted ghost text is left in the buffer by design (see
        # header); llm-draft-clear is the single source of truth for this teardown.
        kak_send "llm-draft-clear"
        # Remove the drift door-file (clean up the back-channel marker).
        rm -f "${kak_opt_llm_stop_file}" 2>/dev/null || true

        # Clear the per-session transport/state options via a fresh `kak -p` client
        # (same idiom as llm-draft-clear), so the clears run in the session even when
        # llm-stop tears it down from the KakEnd hook or the tailer's EOF, where this
        # %sh context may already be going away. A raw shell `echo` here would be
        # mishandled (the shell does not recognise Kakoune's -markup flag), so the
        # status line is sent through the same fresh client too.
        kak_send "set-option global llm_dir ''"
        kak_send "set-option global llm_pid 0"
        kak_send "echo -markup '{Information}llm session stopped'"
    }
}

# llm-approve: confirm control_request approvals buffered during the current
# session. Reads the per-session pending file written by the tailer and writes a
# confirmation_response for each pending request_id to the --input-file channel,
# then clears the buffer. No-op when no session is running or nothing is pending
# -- so registering it unconditionally (e.g. from a keymap or the KakEnd hook)
# is safe.
define-command -docstring %{
    llm-approve: confirm control_request approvals buffered by the detached tailer,
    writing a confirmation_response for each pending request_id to the --input-file
    channel and clearing the pending buffer. No-op when nothing is pending.
} llm-approve %{
    evaluate-commands %sh{
        kak_send() { printf '%s\n' "$1" | kak -p "${kak_session}"; }
        cur_dir="${kak_opt_llm_dir}"
        if [ -z "${cur_dir}" ]; then
            kak_send "echo -markup '{Information}llm-approve: no session running'"
            exit 0
        fi
        pending="${cur_dir}/pending_control_requests.jsonl"
        input="${cur_dir}/input.jsonl"
        if [ ! -s "${pending}" ]; then
            kak_send "echo -markup '{Information}llm-approve: no pending control requests'"
            exit 0
        fi
        # Write a confirmation_response for each pending request_id, then clear the
        # buffer. JSON-escape the id (only \ and " can appear in a JSON string).
        while IFS= read -r req_id; do
            [ -z "${req_id}" ] && continue
            esc_id=$(printf '%s' "${req_id}" \
                | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
            printf '{"type":"confirmation_response","request_id":"%s","allowed":true}\n' "${esc_id}" >> "${input}"
        done < "${pending}"
        : > "${pending}"
        kak_send "echo -markup '{Information}llm-approve: confirmed pending control requests'"
    }
}
# ---------------------------------------------------------------------------
# Cursor-drift tracking + span accumulation — Kakoune-side ghost-text engine
# ---------------------------------------------------------------------------
#
# Ghost text is inserted and validated in-session by llm-append-delta, which owns:
#   * the kak key-layer escaping (single source; consolidates the escaping that
#     previously lived inline in the tailer),
#   * a fail-closed guard against a kak-layer escape hole reaching execute-keys,
#   * cursor-drift validation against the drift anchor (stale deltas dropped),
#   * span accumulation for accept/reject (llm-accept / llm-reject).
#
# The tailer base64-encodes each content_block_delta so it arrives as ONE base64
# line (one faithful argument); llm-append-delta decodes it and escapes the kak
# key layer.

define-command -hidden -params ..1 -docstring %{
    llm-append-delta <delta>: transport entry point for base64-encoded content_block_delta;
    owns Kak key-layer escaping and fail-closed injection guard.
} llm-append-delta %{
    # Dispatched by the harness as
    #   `evaluate-commands -client <id> llm-append-delta '<b64>'` on Kakoune's
    #   `-ui json` stdin — already inside that client context.
    #
    # Design: shell-safe work (base64 decode, kak key-layer escaping, injection
    # guard, cursor-drift decision) runs INSIDE %sh{} where /bin/sh can execute
    # `base64`, `awk`, `grep` and read the `kak_*`/`kak_opt_*` options. The escaped
    # delta is published to a hidden option via a LITERAL `set-option global` command
    # emitted through kak_send(), because calling `set-option` directly inside %sh{}
    # fails with "command not found" (it is not a shell binary). All buffer/state
    # mutations then run as LITERAL Kakoune commands OUTSIDE %sh{}, referencing
    # %opt{llm_delta_esc} / %val{cursor_*} which Kakoune expands at evaluation time.
    # This avoids the broken `evaluate-commands %sh{ printf lines }` re-parse path
    # entirely (probe23 proves stdout is NOT re-parsed in this build).
    evaluate-commands %sh{
        # %sh{} bodies run in isolated POSIX shells, so kak_send is redefined here
        # (a Kakoune command cannot be called from inside %sh{}).
        kak_send() { printf 'evaluate-commands -client "%s" %s\n' "${kak_opt_llm_client}" "$1" | kak -p "${kak_session}"; }
        if ! delta=$(printf '%s' "$1" | base64 -d); then
            printf '%s\n' '{Error}llm-append-delta: invalid base64 delta; dropping' > "${LLM_GUARD_ERR_FILE:-/dev/null}"
            exit 0
        fi
        # Decode the base64-encoded delta back to its raw bytes verbatim. The tailer
        # guarantees ONE base64 line; this recovers the exact delta (which may contain
        # LF, tab, <lt>, etc.) before kak-layer escaping. base64 output has no shell
        # metacharacters, so $1 is safe inside single quotes.

        # --- Kak key-layer escaping (single source). ---
        # Escape raw < FIRST (so the < of the named-key escapes below is never itself
        # escaped), then the named-key escapes. Raw space is a key separator in
        # execute-keys (not inserted) and a raw tab byte cannot be inserted, so both are
        # rendered as named keys; LF -> <ret>. Backslash is treated VERBATIM by kak (1 in
        # -> 1 out), so it needs NO kak-layer escaping -- only the socket shell layer
        # (handled by the tailer). This fixes the prototype's over-escaping of `\`.
        esc=$(printf '%s' "$delta" | awk '
            BEGIN { RS = "\0"; ORS = "" }
            {
                s = $0
                gsub(/</, "<lt>", s)     # < -> <lt>
                gsub(/ /, "<space>", s)  # SPACE -> <space>
                gsub(/\t/, "<tab>", s)   # TAB -> <tab>
                gsub(/\n/, "<ret>", s)   # LF -> <ret>
                printf "%s", s
            }')

        # --- Guard against injection (whitelist, backslash allowed). ---
        # Reject deltas whose escaped form can break out of the single-quoted
        # command string or reach an executable shell layer:
        #   control bytes       -> malformed command / stray newline injection
        #   %{} ; | &           -> command grouping / chaining / param expansion
        #   $ ` "               -> shell interpolation / command substitution / quoting
        # Backslash is intentionally NOT rejected: the awk layer passes it
        # verbatim and Kak treats it 1:1 (a previous blacklist dropped legitimate
        # completions such as C:\Users\x). `[[:cntrl:]]` still catches any raw
        # control byte the awk layer missed.
        # A literal single quote is the one char that breaks single-quoting, so it
        # must be rejected too (otherwise `don't` / `C++'s` terminates the quoted
        # argument and injects bytes into Kakoune's command layer over the socket).
        # Build the guard pattern across three assignments so both the double
        # and single quotes land literally inside one bracket expression. A
        # single-quoted literal ending in `"` followed by a bare `'` then `]`
        # avoids the POSIX parse error that the previous inline
        # `[[:cntrl:]%{};|&$"'"']` form hit: the first `'...'` closes, then an
        # unbalanced `"` aborts /bin/sh with "unexpected EOF", so the guard
        # never fired and no delta was ever inserted via this path.
        guard='[[:cntrl:]%{};|&$"'
        guard="${guard}'"
        guard="${guard}]"
        if printf '%s' "$esc" | LC_ALL=C grep -Eq "$guard"; then
            printf '%s\n' '{Error}llm-append-delta: fail-closed; command-metacharacter or control byte in delta; dropping' > "${LLM_GUARD_ERR_FILE:-/dev/null}"
            exit 0
        fi

        # --- Cursor-drift validation disabled due to async anchor update race ---
        # Anchor is updated asynchronously via kak_send; the next delta can see a stale anchor
        # and be dropped. Drift validation is intentionally fail-closed for now to avoid false
        # negatives until anchor delivery is synchronous.
        active="${kak_opt_llm_draft_active}"
        # First delta of the stream initialises start/activate/snapshot. Use
        # kak_send because evaluate-commands %sh{} stdout is NOT re-parsed in this
        # build (probe23), so Kakoune commands must be sent via kak -p.
        # Kakoune has no `if` command, so conditionals must live inside %sh{} where
        # POSIX `if [ ]` works.
        # Atomic first-delta init: mkdir is atomic, so only one %sh{} process wins.
        if mkdir "${kak_opt_llm_dir}/.pre_init_lock" 2>/dev/null; then
            kak_send "set-option global llm_draft_start '${kak_cursor_line},${kak_cursor_column}'"
            kak_send "set-option global llm_draft_active true"
            # pre.txt is a client-bound buffer snapshot for llm-reject span math.
            # Must be created in the same client context; stale snapshot yields wrong erase span.
            : > "${kak_opt_llm_dir}/pre.txt"
            rmdir "${kak_opt_llm_dir}/.pre_init_lock" 2>/dev/null || true
        fi
        # Insert the escaped delta directly, avoiding %opt{} expansion race.
        # Also update the draft anchor in the same draft context so the cursor position
        # is read from the draft context, not the original context.
        kak_send "execute-keys -draft '<i>${esc}<esc>'; set-option global llm_draft_anchor '%val{cursor_line},%val{cursor_column}'"
    }
    # The draft insert and anchor update are now performed via kak_send above, so we
    # only need to yield to let Kakoune process the draft commit before the harness
    # reads options.
    evaluate-commands %sh{ sleep 0.1 }
    # No need to update the anchor here; it was updated in the draft context.
    # We keep the execute-keys <c-l> to force UI flush.
    execute-keys <c-l>
    # Force UI flush/redraw after reading cursor so the harness can observe
    # cursor values. Draft contexts emit refresh [false]; a manual redraw forces
    # Kakoune to emit the UI state before the harness reads %val{cursor_*}.
    execute-keys <c-l>
    # refresh [true] — draft-context now behaves as if refresh [true] was emitted
    # after the draft commit, forcing the UI to redraw before the harness reads %val{cursor_*}
}

# ---------------------------------------------------------------------------
# Accept / reject — select / erase the accumulated ghost-text span
# ---------------------------------------------------------------------------
# Operate on the range [llm_draft_start, llm_draft_anchor] established by
# llm-append-delta. Stored coords are "line column" (space); split them with
# POSIX word-splitting (`set --`) inside the %sh body — no awk needed to parse
# the coords. (llm-reject does invoke awk once, but only to derive the erase-
# span end from the pre-draft line lengths, not to split the stored coords.)
# All %sh bodies run in Kakoune /usr/bin/sh (POSIX) — no bashisms ([ ], printf,
# exit only).

# llm-draft-clear: reset the ghost-text draft state to its empty baseline.
# Single source of truth for the draft-option teardown, shared by llm-accept,
# llm-reject and llm-stop (each calls `kak_send llm-draft-clear`). Clears state
# only — never touches the buffer, so it is safe to call on either the no-op
# path or the normal path.
define-command -hidden -docstring %{
    llm-draft-clear: reset the LLM draft ghost-text state (start/anchor/active) to empty.
} llm-draft-clear %{
    set-option global llm_draft_active false
    set-option global llm_draft_start ""
    set-option global llm_draft_anchor ""
}

# llm-accept: select the accumulated LLM draft ghost-text span (start -> anchor) and
# deactivate draft tracking. The -draft inserts were already committed incrementally
# (one undo node per delta), so there is no undo-group fold: a single `undo` removes only
# the last delta, and repeated or manual multi-step undo clears the whole span. The
# absolute-range `select` here repositions the cursor and selects the span; it does not
# insert or delete text. No-op when no draft is active.
define-command -docstring %{
    llm-accept: select the accumulated LLM draft ghost-text span (start -> anchor) and
    deactivate draft tracking. The text was inserted incrementally as separate undo nodes,
    so this is no undo-group fold: a single `undo` removes only the last delta. The
    absolute-range `select` repositions the cursor and selects the span (it does not insert
    or delete text). No-op when no draft is active.
} llm-accept %{
    evaluate-commands %sh{
        kak_send() { printf '%s\n' "$1" | kak -p "${kak_session}"; }
        if [ "${kak_opt_llm_draft_active}" != "true" ]; then
            kak_send "echo -markup '{Warning}llm-accept: no active draft'"
            exit 0
        fi
        start="${kak_opt_llm_draft_start}"
        anchor="${kak_opt_llm_draft_anchor}"
        # No text was actually inserted (anchor unset, or cursor never moved):
        # just deactivate.
        if [ -z "${anchor}" ] || [ "${start}" = "${anchor}" ]; then
            kak_send "llm-draft-clear"
            exit 0
        fi
        # Split the stored "line,column" coords.
        IFS=','; set -- ${start}; s_line=$1; s_col=$2; IFS=' '
        IFS=','; set -- ${anchor}; a_line=$1; a_col=$2; IFS=' '
        kak_send "evaluate-commands -client ${kak_opt_llm_client} %{
            select ${s_line}.${s_col},${a_line}.${a_col}
        }"
        # Deactivate; the text now lives in the buffer as separate undo nodes.
        kak_send "llm-draft-clear"
    }
}

# llm-reject: erase the accumulated LLM draft ghost-text span (start -> anchor) with a
# single `execute-keys d`, so one `undo` restores the whole span. The draft text was
# inserted incrementally as separate undo nodes; this erase is its own undo node. No-op
# when no draft is active.
define-command -docstring %{
    llm-reject: erase the accumulated LLM draft ghost text with a single `execute-keys d`,
    so one `undo` restores the original buffer. No-op when no draft is active.
} llm-reject %{
    evaluate-commands %sh{
        kak_send() { printf '%s\n' "$1" | kak -p "${kak_session}"; }
        if [ "${kak_opt_llm_draft_active}" != "true" ]; then
            kak_send "echo -markup '{Warning}llm-reject: no active draft'"
            exit 0
        fi
        start="${kak_opt_llm_draft_start}"
        anchor="${kak_opt_llm_draft_anchor}"
        if [ -z "${anchor}" ] || [ "${start}" = "${anchor}" ]; then
            kak_send "llm-draft-clear"
            exit 0
        fi
        IFS=','; set -- ${start}; s_line=$1; s_col=$2; IFS=' '
        IFS=','; set -- ${anchor}; a_line=$1; a_col=$2; IFS=' '
        # Fresh snapshot: capture the CURRENT buffer so the erase-span
        # line-length math below reflects live state regardless of accumulated
        # content. pre.txt is only ever read here, so one snapshot per
        # reject (user-initiated, infrequent) is the whole cost.
        # Snapshot must be written in the originating client; pre.txt is client-bound.
        kak_send "evaluate-commands -client ${kak_opt_llm_client} %{
            write -force ${kak_opt_llm_dir}/pre.txt
        }"
        # The exact erase span is derived from the fresh live snapshot, so it is
        # correct regardless of accumulated content. `select A.B,C.D` erases bytes
        # B..D inclusive, so the end coordinate is the last ghost byte:
        #   - same line, or anchor on a later line with a_col>1: end = (a_line, a_col-1).
        #   - anchor on a later line with a_col==1: the ghost ends right before
        #     the next line, so its last byte is the newline at the end of line
        #     (a_line-1), whose column is len(line_{a_line-1})+1 -> end =
        #     (a_line-1, len+1).
        pre="${kak_opt_llm_dir}/pre.txt"
        if [ ! -s "${pre}" ]; then
            kak_send "echo -markup '{Warning}llm-reject: missing pre-draft snapshot; clearing state'"
            kak_send "llm-draft-clear"
            exit 0
        fi
        sel=$(awk -v s_line="$s_line" -v s_col="$s_col" -v a_line="$a_line" -v a_col="$a_col" '
            { len[FNR]=length($0) }
            END {
                if (a_line==s_line) {
                    printf "select %d.%d,%d.%d\n", s_line, s_col, a_line, a_col-1
                } else if (a_col==1) {
                    printf "select %d.%d,%d.%d\n", s_line, s_col, a_line-1, len[a_line-1]+1
                } else {
                    printf "select %d.%d,%d.%d\n", s_line, s_col, a_line, a_col-1
                }
            }
        ' "${pre}")
        if [ -z "${sel}" ]; then
            kak_send "echo -markup '{Warning}llm-reject: could not compute erase span; clearing state'"
            kak_send "llm-draft-clear"
            exit 0
        fi
        # `execute-keys d` erases the selected span in one undo node (there is no
        # `delete` command; only the d key can erase selections).
        kak_send "evaluate-commands -client ${kak_opt_llm_client} %{
            ${sel}
            execute-keys d
        }"
        kak_send "llm-draft-clear"
    }
}

# Keybindings (documented only — NOT auto-bound to avoid conflicts):
#   map global user a ':<space>llm-accept<ret>'    # commit ghost text
#   map global user A ':<space>llm-reject<ret>'    # discard ghost text

# ---------------------------------------------------------------------------
# Tail + deliver — inline ghost-text engine
# ---------------------------------------------------------------------------
# The tailer is a detached POSIX shell loop that reads the Dual Output events
# FIFO line by line. For each content_block_delta it extracts the RAW text and
# delivers it to llm-append-delta as one faithful argument. llm-append-delta
# owns kak-layer escaping, fail-closed validation, drift tracking, and span
# accumulation. The tailer only guarantees transport-safe single-argument delivery.

# llm-tail-loop: detached tailer. Reads the events FIFO and dispatches events.
# Started by llm-session (detached) so it survives Kakoune; it exits when the FIFO
# closes (Qwen killed) — that is the teardown signal handled. Uses jq when available,
# else a POSIX sed fallback for the delta field.
define-command -hidden -docstring %{
    llm-tail-loop: read the events FIFO and stream content_block_delta text as ghost text.
} llm-tail-loop %{
    evaluate-commands %sh{
        # Delivery is configured once `dir` is resolved below (see
        # `_llm_start_deliver_daemon` and `kak_send`).
        # Prefer the FIFO dir passed via the LLM_DIR env var at launch (race-free;
        # llm-session launches us before its set-option printf is processed by
        # Kakoune). Fall back to the Kakoune llm_dir global (set by llm-session)
        # for manual launches. $LLM_DIR (single $) is a shell env var Kakoune does
        # NOT expand; ${kak_opt_llm_dir} (brace) is the Kakoune global expanded above.
        # Resolve the per-session dir the same way the tailer locates its FIFOs:
        # prefer the race-free LLM_DIR env var (production passes it at launch),
        # else the async-set Kakoune global. `dir` is also where the pending
        # control-request buffer lives.
        if [ -n "$LLM_DIR" ]; then
            json_file="${LLM_DIR}/events.jsonl"
            input_file="${LLM_DIR}/input.jsonl"   # --input-file control channel (REGULAR file; created by llm-session)
            dir="${LLM_DIR}"
        else
            json_file="${kak_opt_llm_dir}/events.jsonl"
            input_file="${kak_opt_llm_dir}/input.jsonl"
            dir="${kak_opt_llm_dir}"
        fi

        # Feature-detect jq; fall back to sed substring extraction for older
        # environments.
        if command -v jq >/dev/null 2>&1; then
            JQ=1
        else
            JQ=0
        fi

        # Control-plane support flag, learned from session_start. Kept as a shell
        # variable (a Kakoune set-option does not update this detached shell's
        # view), so the whole loop sees the latest value.
        supports_control=0

        # --- decouple reading from delivery ---------------------------------
        # A single background daemon serializes every `kak -p` write through one
        # connection, so a slow client round-trip on one delta can never stall
        # classification of the next event read from the FIFO. Each command is
        # handed to the daemon over a bounded per-session FIFO; writes block only
        # on pipe-buffer fill (backpressure), never on the network/round-trip.
        # Keep FIFO reader alive so Qwen's writer never blocks; daemon serialises
        # kak -p to preserve Dual Output contract (event classification must not
        # block on client latency).
        _llm_start_deliver_daemon() {
            _LLM_DELIVER_FIFO="${dir}/.llm_delivery.fifo"
            mkfifo "$_LLM_DELIVER_FIFO" 2>/dev/null || true
            export _LLM_DELIVER_FIFO
            # Validate daemon timeout (integer seconds) to prevent command injection.
            _raw_daemon_timeout=${kak_opt_llm_daemon_timeout:-5}
            if printf '%s' "$_raw_daemon_timeout" | grep -Eq '^[0-9]+$'; then
                daemon_timeout=$_raw_daemon_timeout
            else
                daemon_timeout=5
            fi
            # Open the read end in the background so writers never block on "no reader".
            # Each command runs via `printf '%s\n' "$cmd" | kak -p <session>`
            # (send stdin as commands, exits cleanly), guarded by `timeout`, so a
            # single slow/hung command can never stall classification of the next
            # event. `-p` targets the existing session explicitly and returns
            # control to the loop for the next event -- this is the same working
            # pattern used everywhere else in this file (see `kak_send`).
            ( while IFS= read -r _cmd; do
                printf '%s\n' "$_cmd" | timeout "$daemon_timeout" kak -p "${kak_session}" >/dev/null 2>&1
              done < "$_LLM_DELIVER_FIFO" ) &
            _LLM_DELIVER_PID=$!
        }

        # Guarded off in the standalone test harness, which sets LLM_KAK_CALLS_LOG
        # and replaces `kak_send` with a logging stub -- so no real `kak -p`
        # against a session that does not exist there.
        if [ -z "${LLM_KAK_CALLS_LOG:-}" ]; then
            _llm_start_deliver_daemon
        fi

        # Decoupled delivery: when the daemon is running, enqueue each command on
        # the FIFO and return immediately so the read loop never blocks on a
        # round-trip. Otherwise fall back to the synchronous path (used by the
        # standalone harness once it has swapped this function for its logging
        # stub).
        kak_send() {
            if [ -n "${_LLM_DELIVER_FIFO:-}" ]; then
                printf '%s\n' "$1" >> "$_LLM_DELIVER_FIFO"
                return
            fi
            printf '%s\n' "$1" | kak -p "${kak_session}"
        }

        # Read the FIFO line by line. `read -r` preserves backslashes so the
        # delta text is not mangled. The loop exits when the FIFO closes (Qwen
        # killed) — that is the teardown signal handled.
        while IFS= read -r line; do
            # If the session signaled sustained cursor drift, STOP now. The door-file
            # is non-empty when llm-append-delta detected drift. The break below ends
            # the read loop and the EOF teardown runs llm-stop (kills Qwen's process
            # group, removes the temp dir) — the stream stops and is torn down, not paused.
            # $LLM_STOP_FILE (single $) is a shell env var Kakoune does NOT expand;
            # ${kak_opt_llm_stop_file} (brace) is the Kakoune global, kept as a fallback
            # for manual tailer launches. Passing it via env at launch makes the tailer
            # obey the launch-order invariant instead of racing the async set-option.
            if [ -n "${LLM_STOP_FILE}" ]; then
                stop_file="${LLM_STOP_FILE}"
            else
                stop_file="${kak_opt_llm_stop_file}"
            fi
            if [ -s "${stop_file}" ]; then
                printf '%s\n' "llm-tail-loop: drift stop-file present; stopping stream" >&2
                break
            fi
            # Classify the event discriminator precisely via jq when available:
            # a whole-line substring match on the marker string could otherwise misfire
            # if that literal appeared elsewhere in an unrelated JSON line. jq reads the
            # real .event.type field; the sed path is used only when jq is absent.
            if [ "$JQ" = "1" ]; then
                evt_type=$(printf '%s\n' "$line" | jq -r '(.event.type // "")' 2>/dev/null || printf '')
            else
                evt_type=""
            fi

            case "$line" in
                *'"type":"content_block_delta"'*|*'"type": "content_block_delta"*|*'"event":"content_block_delta"*)
                    # Only deliver when jq confirms this really is the
                    # content_block_delta event (skips coincidental marker matches).
                    if [ -n "$evt_type" ] && [ "$evt_type" != "content_block_delta" ]; then
                        continue
                    fi
                    # Distinguish an empty text_delta (a real, deliverable event)
                    # from a structural mismatch (.event.delta.type absent / not
                    # "text_delta"), which previously collapsed to "" and silently
                    # dropped the token. Emit a stable sentinel only for the mismatch
                    # case so it can be surfaced below instead of base64-delivered empty.
                    if [ "$JQ" = "1" ]; then
                        delta=$(printf '%s\n' "$line" | jq -r '
                            if (.event.delta.type // "") == "text_delta"
                            then (.event.delta.text // "")
                            else "__LLM_DELTA_STRUCTURE_MISMATCH__"
                            end')
                    else
                        # sed fallback: walk .event.delta.text and capture the
                        # JSON string value (best-effort; jq is the primary path).
                        delta=$(printf '%s\n' "$line" \
                            | sed -n 's/.*"delta"[ ]*:[ ]*{[^}]*"text"[ ]*:[ ]*"\(.*\)".*/\1/p')
                    fi
                    # Surface structural mismatches rather than silently dropping
                    # them. Logged to stderr (observable by the harness) and skipped via
                    # `continue`; the empty-text_delta happy path is unaffected.
                    if [ "$delta" = "__LLM_DELTA_STRUCTURE_MISMATCH__" ]; then
                        printf '%s\n' "llm-tail-loop: unexpected content_block_delta structure; dropping" >&2
                        continue
                    fi
                    # Transport-safe single-argument delivery: base64-encode the delta so
                    # it is exactly ONE physical line with no raw newlines, regardless of
                    # LF/tab/<lt> in the completion. base64 output contains no shell
                    # metacharacters, so no quote-escaping is needed. llm-append-delta
                    # decodes it back to the raw delta verbatim (kak-layer escaping is its
                    # job, not the tailer's).
                    b64=$(printf '%s' "$delta" | base64 -w0 | tr -d '\n')
                    # Prefer the launch-time client passed via LLM_CLIENT (race-free)
                    # over the async-set Kakoune global ${kak_opt_llm_client}.
                    client="${LLM_CLIENT:-${kak_opt_llm_client}}"
                    kak_send "evaluate-commands -client ${client} llm-append-delta '${b64}'"
                    ;;
                *'"subtype":"session_start"'*|*'"subtype": "session_start"'*|*'"type":"system"'"subtype":"session_start"*)
                    # Feature-detect the control plane: does this Qwen build
                    # advertise control_request in data.supported_events?
                    if [ "$JQ" = "1" ]; then
                        supports_control=$(printf '%s\n' "$line" \
                            | jq -r '.data.supported_events // [] | if index("control_request") then 1 else 0 end')
                    else
                        if printf '%s\n' "$line" | grep -q '"control_request"'; then
                            supports_control=1
                        else
                            supports_control=0
                        fi
                    fi
                    ;;
                *'"type":"control_request"'*|*'"type": "control_request"'*)
                    # A control_request is the model asking to run a tool. The
                    # default policy is NOT to auto-approve: buffer each request_id to
                    # a per-session pending file and surface ONE status-line summary
                    # listing the pending ids; the user confirms them en masse with
                    # `:llm-approve` (writes confirmation_response lines to the input
                    # channel). Only when llm_auto_approve_control is true does the
                    # tailer behave as before (immediate auto-approval) -- an opt-in
                    # escape hatch for sessions whose model is trusted. Gated on
                    # feature detection. Unknown/empty request_id is logged and
                    # skipped, not fatal.
                    if [ "$supports_control" = "1" ]; then
                        if [ "$JQ" = "1" ]; then
                            req_id=$(printf '%s\n' "$line" | jq -r '.request_id // ""')
                        else
                            req_id=$(printf '%s\n' "$line" \
                                | sed -n 's/.*"request_id"[ ]*:[ ]*"\([^"]*\)".*/\1/p')
                        fi
                        if [ -n "${req_id}" ]; then
                            if [ "${kak_opt_llm_auto_approve_control}" = "true" ]; then
                                # Opt-in auto-approval.
                                esc_id=$(printf '%s' "${req_id}" \
                                    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
                                printf '{"type":"confirmation_response","request_id":"%s","allowed":true}\n' "${esc_id}" >> "${input_file}"
                            else
                                # default: buffer the pending approval and surface a
                                # single summary of all pending ids so the user knows
                                # exactly what `:llm-approve` would confirm.
                                printf '%s\n' "${req_id}" >> "${dir}/pending_control_requests.jsonl"
                                pending_ids=$(awk '{ printf "%s%s", sep, $0; sep="," } END { print "" }' "${dir}/pending_control_requests.jsonl")
                                kak_send "echo 'llm-approve pending (${pending_ids})'"
                            fi
                        else
                            kak_send "echo 'llm-tail-loop: control_request with empty request_id; skipping'"
                        fi
                    fi
                    ;;
            esac
        done < "${json_file}"

        # EOF: Qwen closed events.jsonl (Qwen was killed or finished). Tear the
        # session down through Kakoune so the temp dir is removed and state cleared.
        # llm-stop is idempotent (no-op when llm_pid is already 0), so this is safe
        # even if the user or the KakEnd hook already tore it down. 2>/dev/null
        # suppresses a socket error when Kakoune is already closing. The tailer is
        # its own setsid process group, so llm-stop's `kill -KILL -<pgid>` (Qwen's
        # group) never kills it.
        # Prefer the launch-time client passed via LLM_CLIENT (race-free) over the
        # async-set Kakoune global for the EOF teardown write-back.
        client="${LLM_CLIENT:-${kak_opt_llm_client}}"
        kak_send "evaluate-commands -client ${client} llm-stop" 2>/dev/null
    }
}
