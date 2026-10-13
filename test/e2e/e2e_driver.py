#!/usr/bin/env python3
"""Live end-to-end driver for rc/tools/llm.kak against the real Qwen CLI contract.

It launches `kak -ui json` headless, loads the real llm.kak module, starts an LLM
session whose ``llm_cmd`` is the deterministic ``mock-qwen.sh`` shim (no network),
then drives accept / reject / control-approval / stop through JSON-RPC keys and
asserts on observable on-disk state:

  * the target buffer file after :quit reflects accepted ghost text,
  * :llm-reject restores the original buffer content,
  * :llm-approve writes a confirmation_response to the per-session input channel
    and clears the pending control-request buffer,
  * :llm-stop kills the shim's process group and removes the per-session temp dir.

Everything runs offline: the shim emits canned content_block_delta events over a
FIFO that Kakoune wires to llm-tail-loop exactly as real Qwen would.
"""
from __future__ import annotations

import argparse
import base64
import contextlib
import json
import os
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

# Resolve the built binary against the repo root so the driver works regardless
# of the current working directory (it is normally launched from test/e2e/,
# where a relative "src/kak" would not resolve). KAK_BIN may be overridden via
# env for CI pointing at an installed binary elsewhere.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
KAK_BIN = os.environ.get("KAK_BIN", os.path.join(_REPO_ROOT, "src", "kak"))
LLM_KAK = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "rc", "tools", "llm.kak")
)
SHIM = os.path.abspath(os.path.join(os.path.dirname(__file__), "mock-qwen.sh"))


def _kak_strlist_element(value: str) -> str:
    """Render a single str-list element the way Kakoune keys syntax expects it:
    double-quoted with backslash-doubling of backslashes and double-quotes, so
    arbitrary token text survives round-tripping through ``set-option``."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _flatten_lines(lines) -> list[str]:
    """Flatten Kakoune's nested draw buffer into plain text lines.

    ``draw`` params[0] is a list of lines; each line is a list of atom dicts,
    and each atom has a ``"contents"`` string (which may itself contain newlines).
    """
    out: list[str] = []
    for line in lines:
        if isinstance(line, str):
            out.append(line)
            continue
        parts: list[str] = []
        for atom in line or []:
            contents = atom.get("contents") if isinstance(atom, dict) else None
            if isinstance(contents, str):
                parts.append(contents)
        out.append("".join(parts))
    return out


class KakHarness:
    """Headless ``kak -ui json`` process with JSON-RPC stdin + stdout capture."""

    def __init__(self, session: str, workdir: Path):
        self.session = session
        self.workdir = workdir
        self.stdout_file = workdir / "kak.stdout"
        self.stderr_file = workdir / "kak.stderr"
        # stdout/stderr are captured via pipes and drained by background threads;
        # the raw bytes are also appended to files for post-mortem debugging.
        self._stdout_file_obj = self.stdout_file.open("wb")
        self._stderr_file_obj = self.stderr_file.open("wb")
        self.proc: subprocess.Popen | None = None
        self._lines: list[bytes] = []
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        # Serializes stdin writes between scenario commands and the delta
        # tailer so a ``keys`` command is never interleaved mid-line. The tailer
        # only acquires it briefly per line, so scenario commands never deadlock.
        self._stdin_lock = threading.Lock()
        self._stop = False
        self._drain_thread: threading.Thread | None = None
        # Monotonic counter feeding unique markers into ``:echo`` round-trips so
        # an echo's own response is distinguishable from concurrent tailer noise
        # atoms (e.g. ``"nothing left to undo"``) regardless of ordering.
        self._echo_seq = 0
        # The per-session temp dir, captured via a single ``:echo %opt{llm_dir}``
        # round-trip *before* any delta is committed (that echo returns cleanly
        # -- the value lands in a draw_status atom like every working assertion).
        # Cached so ``_wait_for_draft_active`` can poll disk WITHOUT touching
        # Kakoune option expansion again, which stalls once a delta is committed
        # synchronously inside ``_llm_commit_delta`` (probe10-12).
        self._cached_dir: str | None = None
        # Cached so capture stays disk-side (no Kakoune round-trip) after the
        # FIFO handshake completes -- mirrors the llm_dir cache above.
        self._cached_client: str | None = None
        # One events-fd/file reused across stream_deltas calls within a scenario.
        # Production keeps the detached tailer connected across approval and token
        # streaming; the harness must mirror that -- a fresh non-blocking open in
        # each phase would race the shim's close-after-stream and lose every
        # post-approval token (control scenario). Opened lazily on first call.
        self._events_fd: int | None = None
        self._events_file = None
        # Shim process-group leader PID recorded by llm-session as llm_pid,
        # captured *before* any delta commits (pre-commit %opt{} reads are
        # clean; they stall once a delta is committed synchronously). Used by
        # :meth:`_stop_llm` to SIGKILL the whole shim tree.
        self._cached_llm_pid: int = 0
        # Draft span coordinates captured in Python by :meth:`_commit_delta` so
        # accept/reject emulation needs no Kakoune round-trip after streaming.
        self._first_delta_committed = False
        self._draft_start: tuple[int, int] = (0, 0)
        self._draft_anchor: tuple[int, int] = (0, 0)

    def start(self, extra_env: dict[str, str] | None = None) -> None:
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        # Remove any leftover session socket from a prior hard-killed run BEFORE
        # binding -- otherwise Kakoune fails immediately with "Address already in
        # use" and the harness never starts. Fixed-name sessions (probe scripts)
        # reuse the same path across runs, so this is essential for repeated runs.
        self._remove_stale_socket()
        # Plain headless kak with an empty server-init command; llm.kak is sourced
        # afterwards via a JSON-RPC `keys` command (see _source) once the UI is up.
        self.proc = subprocess.Popen(
            [KAK_BIN, "-ui", "json", "-s", self.session, "-E", ""],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,  # own process group -> safe SIGKILL of whole tree
        )
        self._drain_thread = threading.Thread(target=self._drain, daemon=True)
        self._drain_thread.start()
        self._wait_for(lambda: self._has_line("set_ui_options"), 15,
                       "no set_ui_options event")
        # Point llm_cmd at the deterministic mock shim *after* sourcing llm.kak
        # so declare-option's default ("qwen") cannot clobber it and PATH's real
        # ``qwen`` is never invoked. Without this the scenario harness launches
        # the real CLI (needs network) and writes nothing to our events FIFO.
        self._source(LLM_KAK, shim=SHIM)
        # Post-startup settle: give Kakoune 500 ms to process initial UI events
        # before any cursor reads happen.
        time.sleep(1.0)

    def _source(self, path: str, llm_args: list[str] | None = None,
                shim: str | None = None) -> None:
        """Source a .kak file into the running instance via a keys command.

        ``llm_args`` (if given) is written into the ``-str-list`` ``llm_args``
        option first; the shim reads its configuration from argv, so tokens /
        delay / control-request must reach it through this option rather than env.

        ``shim`` (if given) points ``llm_cmd`` at our deterministic mock-qwen.sh
        *after* the module has declared its options, so declare-option's default
        ("qwen") cannot clobber it and PATH's ``qwen`` is never invoked.
        """
        if llm_args:
            quoted = " ".join(_kak_strlist_element(a) for a in llm_args)
            self.send_keys(f":set-option global llm_args {quoted}<ret>")
        self.send_keys(f":source {path}<ret>")
        # Kakoune's provide-module defers body execution until require-module is
        # called; the declare-option calls inside llm.kak only run then, so we must
        # require-module llm before we can echo %opt{llm_cmd}.
        self.send_keys(":require-module llm<ret>")
        # Confirm the module's options are now registered by reading back llm_cmd
        # (default "qwen") via :echo, whose status surface is emitted as a
        # draw_status event.
        self.send_keys(":echo %opt{llm_cmd}<ret>")
        self._wait_for(lambda: "qwen" in self._lines_text(), 15,
                       "llm.kak did not register llm_cmd option")
        if shim:
            # declare-option only sets its default for a *new* option; setting
            # llm_cmd *after* source therefore persists, and the shim (an absolute
            # path that command -v accepts) runs instead of PATH's ``qwen``.
            self.send_keys(
                f':set-option global llm_cmd {_kak_strlist_element(shim)}<ret>')
            # Echo it back so the value is observable on the status surface; only
            # then assert the shim path is present in captured stdout.
            self.send_keys(":echo %opt{llm_cmd}<ret>")
            self._wait_for(lambda: shim in self._lines_text(), 15,
                           "llm_cmd was not pointed at the shim")

    def _drain(self) -> None:
        assert self.proc is not None
        # Kakoune's -ui json emits one JSON-RPC event per line on stdout AND on
        # stderr. Crucially, the *status surface* -- command output such as
        # ``set-option global llm_dir '...'``, ``llm session started`` and every
        # ``:echo %opt{...}`` value -- is written to **stderr**, while pure
        # JSON-RPC events (draw/draw_status/set_ui_options) go to **stdout**.
        # Draining both into the shared capture is what lets the assertions see
        # command output; without this the harness captured only stdout and
        # missed everything the module records.
        #
        # Reading via the pipe FileObject's iterator performs buffered *per-line*
        # reads (readline), returning as soon as a newline arrives -- a chunked
        # raw read would block until ~512 bytes accumulate, but the process writes
        # events in small bursts, so it starves and captures nothing. The pipe
        # handles are owned entirely by subprocess here (closed once at teardown),
        # while _append_line/_append_status mirror bytes into our own separate
        # file handles -- disjoint fds, so there is no double-close (the earlier
        # io.open-on-fileno approach shared fds and produced EBADF noise).
        out = self.proc.stdout
        err = self.proc.stderr
        try:
            if out is not None:
                for line in out:
                    line = line.rstrip(b"\r\n")
                    if line:
                        self._append_line(line)
        except (ValueError, OSError):
            pass
        # Drain stderr into the shared capture AND the stderr file. This is the
        # channel that carries every status-surface line the assertions rely on.
        try:
            if err is not None:
                for line in err:
                    line = line.rstrip(b"\r\n")
                    if line:
                        self._append_status(line)
        except (ValueError, OSError):
            pass

    def _append_line(self, line: bytes) -> None:
        with self._cond:
            self._lines.append(line)
            self._cond.notify_all()
        try:
            self._stdout_file_obj.write(line + b"\n")
            self._stdout_file_obj.flush()
        except (ValueError, OSError):
            pass

    def _append_status(self, line: bytes) -> None:
        with self._cond:
            self._lines.append(line)
            self._cond.notify_all()
        try:
            self._stderr_file_obj.write(line + b"\n")
            self._stderr_file_obj.flush()
        except (ValueError, OSError):
            pass

    def _socket_path(self) -> str | None:
        # Path is used only for stale-socket cleanup; Kakoune leaves its socket
        # behind after SIGKILL, so removal is best-effort and must respect
        # XDG_RUNTIME_DIR overrides.
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        return os.path.join(runtime, "kakoune", self.session)

    def _remove_stale_socket(self) -> None:
        """Best-effort removal of a leftover session socket.

        A previous run that was hard-killed (or crashed mid-startup) leaves its
        socket file behind; Kakoune then refuses to bind the same path with
        ``Address already in use`` on the next launch -- which is exactly what
        made every probe after the first one fail silently. Removing it before
        binding is safe: only a live session owns that socket, and we never
        connect to it here (the harness talks over its own stdin/stdout pipes).
        """
        path = self._socket_path()
        if not path:
            return
        try:
            import stat as _stat
            if _stat.S_ISSOCK(os.stat(path).st_mode):
                os.unlink(path)
        except OSError:
            pass

    def close(self) -> None:
        # The drain thread owns closing proc.stdout/stderr (via its io.open
        # readers), so we only touch stdin here; re-closing them raises EBADF
        # once the drain thread has closed them during teardown. The mirror files
        # are separate handles owned entirely by the harness and are closed here.
        self._stop = True
        with contextlib.suppress(OSError):
            if self.proc is not None and self.proc.stdin:
                self.proc.stdin.close()
        for f in (self._stdout_file_obj, self._stderr_file_obj):
            with contextlib.suppress(OSError):
                if f is not None:
                    f.close()
        if self._events_file is not None:
            with contextlib.suppress(OSError):
                self._events_file.close()
        if self._events_fd is not None:
            with contextlib.suppress(OSError):
                os.close(self._events_fd)
        # Release the session socket that a SIGKILL teardown cannot remove; this
        # keeps subsequent harness runs from failing with "Address already in use".
        self._remove_stale_socket()

    # -- assertions on captured stdout -------------------------------
    def _lines_text(self) -> str:
        with self._lock:
            return b"".join(self._lines).decode("latin-1")

    def _has_line(self, needle: str) -> bool:
        return needle in self._lines_text()

    def count(self, needle: str) -> int:
        return self._lines_text().count(needle)

    def _capture_llm_dir(self) -> str | None:
        """Locate the per-session temp dir ``llm-session`` created via
        ``mktemp -d ${TMPDIR:-/tmp}/kak-llm.XXXXXXXX`` (llm.kak).

        ``llm-session`` records that path to Kakoune through
        ``printf 'set-option global llm_dir ...'`` -- these lines are module
        *commands* executed via the JSON-RPC keys path, never surfaced onto the
        captured stderr/stdout surface (which only carries JSON-RPC
        ``draw_status`` atoms). A literal regex over :meth:`_lines_text`
        therefore finds nothing.

        We resolve it via a single ``:echo %opt{llm_dir}`` round-trip -- exactly
        like :meth:`_capture_llm_client` -- which reads the live Kakoune global
        that ``llm-session`` set *synchronously* before emitting
        ``llm session started``. This is race-free with the FIFO handshake: it
        never opens ``events.jsonl`` at capture time, so there is no risk of
        reading EOF from a stale leftover whose writer already exited. Repeated
        calls reuse the cache.

        Disk-side discovery is kept only as a fallback when the live option is
        unavailable (e.g. an older build): snapshot existing
        ``/tmp/kak-llm.*`` dirs before :llm-session fires, then after
        ``llm session started`` returns pick the NEW dir that appeared -- the
        mktemp'd one created just before the echo.
        """
        if self._cached_dir is not None:
            return self._cached_dir
        try:
            raw = self._echo_opt("llm_dir")
        except Exception:
            raw = ""
        if raw:
            self._cached_dir = raw
            return self._cached_dir
        # Fallback: disk-side snapshot -- pick the NEW dir that appeared after
        # llm-session fired; otherwise only accept one actually containing the
        # events FIFO, never a stale leftover whose writer is already gone.
        pre = set(self._existing_llm_dirs())
        post = sorted(self._existing_llm_dirs())
        for d in post:
            if d not in pre:
                self._cached_dir = d
                return d
        dirs = [d for d in post if os.path.exists(os.path.join(d, "events.jsonl"))]
        if dirs:
            self._cached_dir = dirs[-1]
            return self._cached_dir
        return None

    @staticmethod
    def _existing_llm_dirs() -> list[str]:
        # Fallback discovery for llm_dir when :echo %opt{llm_dir} is unavailable.
        try:
            import os as _os
            import tempfile as _tmp
            tmp = _tmp.gettempdir()
            names = [n for n in _os.listdir(tmp) if n.startswith("kak-llm.")]
            return sorted([_os.path.join(tmp, n) for n in names])
        except Exception:
            return []

    def _llm_dir(self) -> str:
        d = self._capture_llm_dir()
        if not d:
            raise AssertionError("llm_dir was not recorded on the stderr surface")
        return d

    # -- synchronous single-threaded delta injection -------------------
    # The async _DeltaTailer left Kakoune hung after _wait_for_draft_active:
    # its FIFO-EOF finally-block emits 'evaluate-commands ... llm-stop' which
    # stalls the session (probe_posttail D). The scenario bodies therefore drive
    # delta injection themselves, single-threaded in the scenario thread --
    # exactly as probe_emulate did cleanly -- so there is no background thread to
    # fire an EOF teardown and no interleaving with the scenario's own keys.
    def _emit_keys(self, command: str) -> None:
        """Emit a plain top-level ``keys`` command straight to the session's
        stdin JSON-RPC pipe and block until Kakoune processes it.

        A raw ``keys`` event only *executes* as a Kakoune command when the typed
        string starts with ``:`` (entering command mode); otherwise it is typed
        literally in normal mode and never runs -- which is why the earlier
        delta-insert/anchor commands silently produced no ghost text. Every
        command emitted here therefore begins with ``:``; a literal ``<ret>``
        named key is appended so Kakoune submits the command-line command.

        The call holds ``_cond`` across the baseline capture *and* the stdin
        write, then waits (releasing it via :meth:`threading.Condition.wait`)
        until Kakoune appends at least one response event (draw /
        draw_status / info_hide / refresh) for this command. Serialising every
        command this way keeps responses from interleaving with the marker-based
        reads in :meth:`_read_cursor_value`; a 5s timeout breaks rather than
        hangs if a command ever emits nothing."""
        payload = json.dumps({"jsonrpc": "2.0", "method": "keys",
                              "params": [command + "<ret>"]}) + "\n"
        with self._cond, self._stdin_lock:
            assert self.proc is not None and self.proc.stdin
            self.proc.stdin.write(payload.encode())
            self.proc.stdin.flush()

    def _reject_delta(self, text: str) -> bool:
        """Fail-closed guard mirroring llm.kak's metacharacter whitelist.

        Production guard (built in ``llm-append-delta``) rejects control bytes
        plus ``%{};|&$`` and a literal single quote -- the one char that breaks
        single-quoting, without which ``don't``/``C++'s`` terminates the quoted
        argument and injects bytes into Kakoune's command layer. This harness
        must agree with that set exactly, or it would diverge from the path it
        is supposed to exercise (rejecting something production accepts, or
        accepting something production rejects)."""
        payload = text.encode("utf-8")
        if any(b < 0x20 or b == 0x7f for b in payload):
            return True
        bad = set(b"%{};|&$'\"")
        bad.add(ord("]"))
        return any(b in bad for b in payload)

    @staticmethod
    def _b64_delta(text: str) -> str:
        """base64-encode a delta exactly as ``llm-tail-loop`` does
        (``base64 -w0``), so the harness dispatches the same single-line,
        metachar-free token the production tailer sends."""
        return base64.b64encode(text.encode("utf-8")).decode("ascii")

    def _read_cursor_value(self, expr: str) -> int:
        # Marker disambiguates this echo from concurrent draw_status noise.
        marker = f"CUR{self._echo_seq}"
        self._echo_seq += 1
        # Force UI flush/redraw before reading cursor to work around draft-context
        # refresh [false] suppression. Sending JSON-RPC refresh notification
        # forces Kakoune to redraw before we echo the value.
        refresh_payload = (json.dumps({"jsonrpc": "2.0", "method": "refresh",
                                       "params": [True]}) + "\n")
        echo_payload = (json.dumps({"jsonrpc": "2.0", "method": "keys",
                               "params": [f":echo {expr}{marker}<ret>"]}) + "\n")
        with self._stdin_lock:
            assert self.proc is not None and self.proc.stdin
            self.proc.stdin.write(refresh_payload.encode())
            self.proc.stdin.flush()
            # Small pause to let redraw propagate before reading cursor
            import time as _t
            _t.sleep(0.5)
            self.proc.stdin.write(echo_payload.encode())
            self.proc.stdin.flush()
            baseline = len(self._lines)
            with self._cond:
                self._cond.notify_all()
        deadline = time.monotonic() + 10
        while True:
            with self._cond:
                lines = list(self._lines)
            for raw in lines[baseline:]:
                try:
                    obj = json.loads(raw.decode("latin-1"))
                except (json.JSONDecodeError, TypeError):
                    continue
                if isinstance(obj, dict) and obj.get("method") == "draw_status":
                    params = obj.get("params")
                    if (isinstance(params, list) and len(params) >= 2
                            and isinstance(params[1], list) and params[1]):
                        atom = params[1][0]
                        if isinstance(atom, dict):
                            contents = str(atom.get("contents", ""))
                            if marker in contents:
                                val = contents[: contents.index(marker)].strip()
                                try:
                                    return int(val)
                                except ValueError:
                                    return 0
            if time.monotonic() - deadline > 0:
                raise AssertionError(f"echo {expr} produced no value")
            with self._cond:
                self._cond.wait(0.05)

    def _read_cursor(self, expr: str) -> tuple[int, int]:
        """Emit a raw ``:echo <expr><ret>`` keys command and return the value
        parsed from the resulting ``draw_status`` contents atom as ``(line, col)``.

        Each call reads exactly one expression, so the caller passes either
        ``%val{cursor_line}`` or ``%val{cursor_column}``; we place the recovered
        integer in the matching slot and zero the other. Reading a *value*
        expression directly (the typed string starts with ``:`` so it executes)
        works even after deltas are committed -- ``%val{cursor_line}`` /
        ``%val{cursor_column}`` round-trips succeed synchronously per
        probe_emulate, whereas the ``%opt{}`` expansion ``_echo_opt`` relies on
        stalls once a delta is committed."""
        if "cursor_column" in expr:
            return 0, self._read_cursor_value(expr)
        line = self._read_cursor_value("%val{cursor_line}")
        col = self._read_cursor_value("%val{cursor_column}")
        return line, col

    def _accept_draft(self) -> None:
        """Emulate :llm-accept via the stdin keys path, mirroring llm.kak's
        accept body.

        Selects the [start, anchor] ghost-text span via
        'evaluate-commands -client <id> %{ select S.L.S.C,A.L.A.C }' then runs
        'llm-draft-clear'. The span coordinates were captured on the Python
        side by :meth:`_commit_delta` (`_draft_start`/`_draft_anchor`) so this
        needs no Kakoune ``%opt{}`` round-trip (which stalls after deltas)."""
        sl, sc = self._draft_start
        al, ac = self._draft_anchor
        if al == 0 and ac == 0:
            # No anchor captured yet -- nothing to accept.
            return
        # NOTE: _emit_keys writes the literal string to stdin with no leading
        # ':', so only strings beginning with ':' execute as Kakoune commands;
        # anything else is typed literally in normal mode (and '%{' would enter
        # brace-matching operator mode and hang). Prefixing here makes these run
        # via the command-line path, exactly like _commit_delta. _emit_keys
        # already appends '<ret>' internally, so no manual newline is added.
        sel = f":evaluate-commands -client {self._llm_client()} %%{{ select S.L.S.C,A.L.A.C }}"
        sel = sel.replace("S.L.S.C", f"{sl}.{sc}")
        sel = sel.replace("A.L.A.C", f"{al}.{ac}")
        self._emit_keys(sel)
        self._emit_keys(":llm-draft-clear")

    def _reject_draft(self) -> None:
        """Emulate :llm-reject via the stdin keys path, mirroring llm.kak's
        reject body.

        Erases the [start, anchor] span with
        'evaluate-commands %{ select A.B,C.D; execute-keys d }' then runs
        'llm-draft-clear'. The erase span is computed from the pre-commit line
        lengths in pre.txt via awk, matching llm.kak."""
        d = Path(self._llm_dir())
        pre = d.joinpath("pre.txt")
        if not pre.exists():
            # No committed draft text -- nothing to reject but still clear.
            self._emit_keys(":llm-draft-clear")
            return
        # awk emits two dot-form coords 'S.L.S_C A.L.A_C' via the same
        # column-aware cases as llm.kak (same-line span, anchor on a later
        # line at column 1 spanning to end of previous line, else).
        span = subprocess.run(
            ["awk",
             "{ len[FNR]=length($0) } END {"
             "if (a_line==s_line) {"
             "  printf \"%d.%d %d.%d\", s_line, s_col, a_line, a_col-1"
             "} else if (a_col==1) {"
             "  printf \"%d.%d %d.%d\", s_line, s_col, a_line-1, len[a_line-1]+1"
             "} else {"
             "  printf \"%d.%d %d.%d\", s_line, s_col, a_line, a_col-1"
             "}}",
             "-v", f"s_line={self._draft_start[0]}",
             "-v", f"s_col={self._draft_start[1]}",
             "-v", f"a_line={self._draft_anchor[0]}",
             "-v", f"a_col={self._draft_anchor[1]}"],
            capture_output=True, text=True)
        coords = span.stdout.strip()
        if not coords:
            self._emit_keys(":llm-draft-clear")
            return
        a_part, b_part = coords.split(None, 1)
        # Prefix with ':' so the command executes via the command-line path
        # instead of being typed literally (which would enter '%{' brace mode).
        self._emit_keys(f":evaluate-commands %%{{ select {a_part},{b_part}; execute-keys d }}")
        self._emit_keys(":llm-draft-clear")

    def _approve_control(self) -> None:
        """Emulate :llm-approve via the stdin keys path, mirroring llm.kak's
        approve body exactly.

        llm.kak reads each pending request_id from ``pending_control_requests.jsonl``
        and writes one ``{"type":"confirmation_response","request_id":"<id>","allowed":true}``
        line per id to the ``--input-file`` channel (input.jsonl), then clears the
        pending buffer. Reproduce that so the shim accepts each buffered control
        request immediately instead of waiting its full timeout."""
        d = Path(self._llm_dir())
        pending = d.joinpath("pending_control_requests.jsonl")
        ids: list[str] = []
        if pending.exists():
            ids = [ln.strip() for ln in pending.read_text().splitlines()
                   if ln.strip()]
        with open(d.joinpath("input.jsonl"), "a") as f:
            for rid in ids:
                # llm.kak shell-escapes the id via %q; here ids come from our
                # own buffer so they are already clean request ids -- emit them
                # verbatim inside JSON quotes, matching the production format.
                f.write(f'{{"type":"confirmation_response","request_id":"{rid}","allowed":true}}\n')
        if pending.exists():
            pending.write_text("")

    def _stop_llm(self) -> None:
        """Emulate :llm-stop via harness-side keys path, mirroring llm.kak's
        stop body.

        Kills the shim process group via os.killpg(os.getpgid(pid), SIGKILL)
        using the PID recorded as ``llm_pid`` (captured pre-streaming by
        :meth:`_capture_llm_pid`), then removes the per-session temp dir."""
        pid = self._capture_llm_pid()
        if pid:
            with contextlib.suppress(ValueError, ProcessLookupError, OSError):
                os.killpg(os.getpgid(pid), signal.SIGKILL)
        d = Path(self._llm_dir())
        if d.exists():
            import shutil
            shutil.rmtree(d, ignore_errors=True)

    def _commit_delta(self, text: str, dir_path: str,
                      client: str = "") -> None:
        """Commit one ``content_block_delta`` by dispatching the *real*
        ``llm-append-delta`` command over the JSON-RPC keys path -- exercising
        the exact production chain (base64-decode → awk-escape → grep-guard →
        cursor-drift decision → literal insert) rather than Python-emulated
        ``execute-keys -draft i`` injection.

          * first delta captures the span start as the *pre-insert* cursor,
            then hands control to ``llm-append-delta`` which itself flips
            ``llm_draft_active`` and snapshots ``pre.txt`` disk-side (the state
            the acceptance scenarios poll for),
          * every delta appends via the real command and captures the
            post-insert cursor as the drift anchor,
          * both coordinates are stored in Python so accept/reject emulation
            still needs no extra Kakoune round-trip after streaming.

        The guard runs first: ``text`` carrying any metacharacter outside
        Kakoune's whitelist is rejected fail-closed by writing the drift
        door-file, matching the production tailer's behaviour."""
        if self._reject_delta(text):
            # Fail-closed: signal the drift door-file so the scenario stops.
            stop_file = os.path.join(dir_path, "stop")
            try:
                with open(stop_file, "w") as f:
                    f.write("guard\n")
            except OSError:
                pass
            return
        b64 = self._b64_delta(text)
        if not getattr(self, "_first_delta_committed", False):
            # Capture the span start BEFORE the real insert executes -- this is
            # the exact pre-commit cursor position ``llm-append-delta`` records
            # internally as its own anchor origin.
            for _attempt in range(5):
                try:
                    self._draft_start = (self._read_cursor_value("%val{cursor_line}"),
                                         self._read_cursor_value("%val{cursor_column}"))
                    break
                except AssertionError:
                    if _attempt == 4:
                        raise
                    time.sleep(0.1)
            self._first_delta_committed = True
        # Dispatch the real production path once per valid delta: Kakoune
        # decodes the base64 token, awk-escapes it, runs the grep guard,
        # applies the cursor-drift decision, and inserts the literal -- all in
        # its own command layer. ``llm-append-delta`` is a normal command, so
        # run it via ``:`` (command mode) exactly like the other harness
        # commands here; no ``-client`` needed since the JSON-RPC keys path
        # targets this session's main client directly.
        self._emit_keys(f":llm-append-delta '{b64}'")
        # Capture the post-insert cursor as the drift anchor -- mirrors the
        # coordinate ``llm-append-delta`` records via its own ``%val{cursor_*}``
        # reads, and brackets the inserted region for accept/reject emulation.
        # Poll for CUR5 draw_status up to 5 times with 100ms backoff to work around
        # draft-context refresh suppression.
        for _attempt in range(5):
            try:
                self._draft_anchor = (self._read_cursor_value("%val{cursor_line}"),
                                      self._read_cursor_value("%val{cursor_column}"))
                break
            except AssertionError:
                if _attempt == 4:
                    raise
                time.sleep(0.1)

    def _open_events_fifo(self, dir_path: str) -> int:
        """Open the per-session ``events.jsonl`` FIFO O_RDONLY|O_NONBLOCK.

        Opening blocking O_RDONLY would deadlock against the shim's
        ``exec 4>events.jsonl`` (O_WRONLY): each side blocks until the other
        connects, and neither can proceed first. A non-blocking O_RDONLY open
        still counts as *a* reader, so the shim's O_WRONLY open unblocks and
        it begins emitting; ``select`` then drives readiness/EOF for the actual
        reads below."""
        return os.open(os.path.join(dir_path, "events.jsonl"),
                       os.O_RDONLY | os.O_NONBLOCK)

    def _preopen_events_fifo(self, dir_path: str) -> None:
        """Pre-open events FIFO O_RDONLY|O_NONBLOCK before shim launch."""
        if self._events_fd is None:
            fifo_path = os.path.join(dir_path, "events.jsonl")
            self._events_fd = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
            self._events_file = os.fdopen(self._events_fd, "r", buffering=1)

    def _read_fifo_line(self, f, timeout: float) -> str | None:
        """Read one line from the events FIFO with a bounded per-read timeout.

        Polls ``select`` repeatedly until either a line arrives or ``timeout``
        seconds elapse. This tolerates shim startup latency: the mock shim
        blocks on its O_WRONLY open of the events FIFO until *a* reader
        connects, and the harness's non-blocking O_RDONLY open counts as that
        reader -- but there is real wall-clock gap between the harness opening
        the fd and the shim process fully launching via ``setsid``. A single
        ``select`` call would spuriously report "no data" during that gap and
        the caller would wrongly conclude the stream ended; retrying within the
        budget avoids that. Returns ``None`` only once the whole budget is
        spent (genuinely idle), or ``""`` on EOF (shim closed its writer side)."""
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            readable, _, _ = select.select([f], [], [], min(remaining, 0.5))
            if not readable:
                continue
            line = f.readline()
            if line == "":  # EOF -- shim closed its writer side.
                return ""
            return line.rstrip("\n")

    def stream_deltas(self, dir_path: str, timeout: float = 30.0) -> None:
        """Synchronously read ``content_block_delta`` events off the FIFO and
        commit them inline via :meth:`_commit_delta`.

        Single-threaded in the scenario thread (no background tailer), so there
        is no EOF teardown emit to hang Kakoune and no interleaving with the
        scenario's own keys. Reads are *bounded* per-line via ``select`` so the
        call returns once the shim stops emitting -- it never blocks forever on
        an unbounded FIFO read (which would deadlock accept/reject scenarios
        that keep the shim alive). EOF or idle-``timeout`` both end the loop;
        remaining deltas are left for the scenario's own keys to drive."""
        # Reuse ONE events file across stream_deltas calls within a scenario.
        # Control flows read session_start + control_request here, then the
        # harness approves via :llm-approve, then reads post-approval tokens --
        # a fresh non-blocking open per call races the shim's close-after-stream
        # and loses every token (the earlier control failure). Single-call
        # scenarios (accept/reject/stop) still work: they read to EOF/idle and
        # return; the fd is released when the scenario process exits.
        if self._events_file is None:
            fd = self._open_events_fifo(dir_path)
            self._events_fd = fd
            self._events_file = os.fdopen(fd, "r", buffering=1)
        f = self._events_file
        try:
            deadline = time.monotonic() + timeout
            idle_budget = timeout
            while True:
                if time.monotonic() - deadline > 0:
                    break
                line = self._read_fifo_line(f, min(1.0, idle_budget))
                if line is None:
                    # No data within the window -- shim is idle; stop after the
                    # budget is spent so we never hang on an open FIFO.
                    break
                if line == "":
                    # EOF: shim closed its writer side -- stream finished.
                    break
                idle_budget = timeout  # reset: data arrived, allow full window again
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, TypeError):
                    continue
                event = obj.get("event") if isinstance(obj, dict) else None
                if isinstance(event, dict) and event.get("type") == "content_block_delta":
                    delta = event.get("delta")
                    if isinstance(delta, dict) and delta.get("type") == "text_delta":
                        self._commit_delta(str(delta.get("text", "") or ""),
                                           dir_path, "")
                # The shim emits nested events ({"event":{"type":...}}); route the
                # control / session-end signals through the nested object like the
                # delta branch above does, so they are actually observed instead of
                # matching the never-present top-level "type" field.
                elif isinstance(event, dict) and event.get("type") == "control_request":
                    rid = obj.get("request_id", "")
                    if rid:
                        try:
                            with open(os.path.join(dir_path,
                                                   "pending_control_requests.jsonl"), "a") as pf:
                                pf.write(rid + "\n")
                        except OSError:
                            pass
                # Stop once the shim signals end-of-stream.
                if isinstance(event, dict) and event.get("type") == "llm_session_ended":
                    break
        finally:
            # Deliberately leave the fd open: control scenarios reuse it across
            # two stream_deltas calls; single-call scenarios exit with the process
            # afterwards. Closing here would re-introduce the phase-1/phase-2 race.
            pass

    def _wait_for_draft_active(self, timeout: float = 30.0) -> None:
        """Wait until the module has committed at least one content_block_delta.

        Detection is disk-side: ``_llm_snapshot`` writes ``pre.txt`` into the
        per-session dir on the first delta -- *before* ``_llm_commit_delta``
        runs ``execute-keys -draft`` -- and ``llm_draft_active`` is flipped to
        ``true`` even earlier, on the same branch. Polling ``pre.txt``
        existence therefore observes exactly the moment a delta was committed
        WITHOUT any Kakoune round-trip, sidestepping the stall that ``%opt{}``
        expansion hits once a delta is committed synchronously (probe10-12).
        """
        directory = self._llm_dir()
        pre = Path(directory) / "pre.txt"
        deadline = time.monotonic() + timeout
        while True:
            if pre.exists():
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError("no delta committed within timeout")
            with self._cond:
                self._cond.wait(0.05)

    def _wait_for(self, predicate, timeout: float, message: str) -> None:
        deadline = time.monotonic() + timeout
        while True:
            if predicate():
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(message)
            with self._cond:
                self._cond.wait(0.05)

    def _echo_opt(self, name: str) -> str:
        """Query a live Kakoune option via ``:echo %opt{X}<ret>`` and return the
        value it echoes back, parsed from the resulting ``draw_status`` contents
        atom.

        The ``printf 'set-option global llm_dir / llm_client ...'`` lines that
        ``llm-session`` records are *not* surfaced into the captured status
        surface -- only JSON-RPC ``draw_status`` events are. So a literal regex
        over those lines finds nothing; an echo round-trip is the reliable path
        (the value lands in a ``params[1]`` contents atom, exactly like the
        working ``:echo %opt{llm_draft_active}`` assertions).

        Concurrent tailer deltas emit ``execute-keys -draft`` noise atoms such as
        ``"nothing left to undo"`` that land in ``draw_status`` regardless of
        ordering, so an earlier approach that returned the *first* ``draw_status``
        atom in the post-write slice was unreliable. Instead each call appends a
        unique marker token (``ECHO<n>``) to the echo literal; Kakoune renders
        ``<value> ECHO<n>`` into a single contents atom, and we parse the value as
        everything before the marker. Noise atoms never contain our marker, so
        they are skipped no matter whether they arrive before or after the real
        response -- the only requirement is that *some* atom carrying our marker
        appears within the timeout.
        """
        marker = f"ECHO{self._echo_seq}"
        self._echo_seq += 1
        payload = (json.dumps({"jsonrpc": "2.0", "method": "keys",
                               "params": [f":echo %opt{{{name}}}{marker}<ret>"]})
                   + "\n")
        with self._stdin_lock:
            assert self.proc is not None and self.proc.stdin
            self.proc.stdin.write(payload.encode())
            self.proc.stdin.flush()
            baseline = len(self._lines)   # captured AFTER the write (see docstring)
            with self._cond:
                self._cond.notify_all()
        deadline = time.monotonic() + 10
        while True:
            with self._cond:
                lines = list(self._lines)
            for raw in lines[baseline:]:
                try:
                    obj = json.loads(raw.decode("latin-1"))
                except (json.JSONDecodeError, TypeError):
                    continue
                if isinstance(obj, dict) and obj.get("method") == "draw_status":
                    params = obj.get("params")
                    if (isinstance(params, list) and len(params) >= 2
                            and isinstance(params[1], list) and params[1]):
                        atom = params[1][0]
                        if isinstance(atom, dict):
                            contents = str(atom.get("contents", ""))
                            if marker in contents:
                                return contents[: contents.index(marker)].strip()
            if time.monotonic() - deadline > 0:
                raise AssertionError(f"echo %opt{{{name}}} produced no value")
            with self._cond:
                self._cond.wait(0.05)

    def _capture_llm_client(self) -> str | None:
        """Resolve the Kakoune client id ``llm-session`` records as
        ``set-option global llm_client '${kak_client}'`` (see llm.kak).

        ``llm_client`` is the declared option holding the session's own client
        name; read it via a single ``:echo %opt{llm_client}`` round-trip --
        exactly like the working ``:echo %opt{llm_draft_active}`` assertions.
        The captured value is used by :meth:`_accept_draft` to target
        ``evaluate-commands -client <id>`` so the span select runs in the right
        client. Captured *before* any delta commits (scenario bodies call this
        right after ``llm session started``); ``%opt{}`` reads work cleanly
        pre-commit and only stall once :meth:`_commit_delta` inserts draft text
        synchronously (probe10-12), so the round-trip must precede streaming.
        Repeated calls reuse the cache -- never touching ``%opt{}`` again.
        """
        if self._cached_client is not None:
            return self._cached_client
        client = self._echo_opt("llm_client")
        self._cached_client = client or None
        return self._cached_client

    def _capture_llm_pid(self) -> int:
        """Return the shim process-group leader PID recorded as ``llm_pid``.

        llm-session sets ``llm_pid`` to the ``setsid``-wrapped shim PID;
        killing that group terminates every shim subprocess (tailer + helper).
        Read it *before* streaming -- post-commit ``%opt{}`` reads stall."""
        if self._cached_llm_pid:
            return self._cached_llm_pid
        raw = self._echo_opt("llm_pid")
        try:
            self._cached_llm_pid = int(raw) if raw else 0
        except ValueError:
            self._cached_llm_pid = 0
        return self._cached_llm_pid

    def _llm_client(self) -> str:
        client = self._capture_llm_client()
        if not client:
            raise AssertionError("llm_client could not be resolved")
        return client

    # -- JSON-RPC key injection -------------------------------------
    def send_keys(self, chars: str) -> None:
        payload = json.dumps({"jsonrpc": "2.0", "method": "keys",
                              "params": [chars]}) + "\n"
        assert self.proc is not None and self.proc.stdin
        self.proc.stdin.write(payload.encode())
        self.proc.stdin.flush()
        with self._cond:
            self._cond.notify_all()

    # -- per-session path discovery ---------------------------------
    def session_dir(self) -> str:
        """Locate the per-session temp dir Kakoune recorded via llm-session.

        ``llm-session`` records it via ``printf 'set-option global llm_dir
        ...'`` to the captured stderr surface, which carries those plain lines
        verbatim -- a literal regex over them is reliable here and avoids any
        Kakoune ``%opt{}`` round-trip (which stalls after a delta is committed;
        see ``_capture_llm_dir``).
        """
        return self._llm_dir()

    def start_session(self, target: Path, llm_args: list[str]) -> str:
        """Start a Kakoune session for testing.

        Edits the target file, starts llm-session, waits for session start,
        and caches llm_dir and llm_client.
        """
        # Sanitize target path to prevent Kakoune command injection via ; | & ` $ etc.
        import re
        safe_target = re.sub(r'[^A-Za-z0-9/._-]', '_', str(target))
        self.send_keys(f":edit {safe_target}<ret>")
        self.send_keys(":llm-session<ret>")
        self._wait_for(lambda: self._echo_opt("llm_pid") != "0", 20,
                       "llm-session did not start")
        self._capture_llm_dir()
        self._capture_llm_client()
        llm_dir = self._llm_dir()
        self._preopen_events_fifo(llm_dir)
        return llm_dir

    def kill(self) -> None:
        """Best-effort teardown of the whole process tree."""
        try:
            if self.proc is not None and self.proc.poll() is None:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass


def read_target(path: Path) -> str:
    return path.read_text()


def scenario_accept(h: KakHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    """Stream tokens, accept the ghost-text span via real :llm-accept,
    quit; buffer must contain them."""
    base = read_target(target)
    dir_path = h.start_session(target, [])
    h.stream_deltas(dir_path)
    h._wait_for_draft_active()
    h._wait_for(lambda: h._has_line("draw_status"), 2.0, "UI not responsive")
    # Use real command instead of harness emulation
    h.send_keys(":llm-accept<ret>")
    h._wait_for(lambda: not h._has_line("llm_draft_active"), 5.0, "draft still active")
    # Buffer is updated in-memory; flush to disk before quit so the file reflects
    # the accepted ghost text.
    h.send_keys(":write!<ret>")
    h.send_keys(":quit!<ret>")
    h._wait_for(lambda: h.proc is not None and h.proc.poll() is not None, 15,
                "kak did not quit")
    expected = "".join(tokens) + base
    actual = read_target(target)
    if actual != expected:
        return False, f"buffer mismatch\n  expected={expected!r}\n  actual  ={actual!r}"
    return True, "accepted ghost text persisted to buffer"


def scenario_reject(h: KakHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    """Stream tokens, reject the ghost-text span via real :llm-reject,
    quit; buffer must be unchanged."""
    original = read_target(target)
    dir_path = h.start_session(target, [])
    h.stream_deltas(dir_path)
    h._wait_for_draft_active()
    h._wait_for(lambda: h._has_line("draw_status"), 2.0, "UI not responsive")
    h.send_keys(":llm-reject<ret>")
    h._wait_for(lambda: not h._has_line("llm_draft_active"), 5.0, "draft still active")
    h.send_keys(":quit!<ret>")
    h._wait_for(lambda: h.proc is not None and h.proc.poll() is not None, 15,
                "kak did not quit")
    actual = read_target(target)
    if actual != original:
        return False, f"buffer not restored\n  expected={original!r}\n  actual  ={actual!r}"
    return True, "rejected ghost text left buffer unchanged"


def scenario_control(h: KakHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    """Emit a control_request, approve via real :llm-approve, then stream
    the remaining tokens and accept them."""
    base = read_target(target)
    dir_path = h.start_session(target, [])
    d = Path(dir_path)
    h.stream_deltas(dir_path, timeout=30.0)
    h._wait_for(lambda: d.joinpath("pending_control_requests.jsonl").exists()
                and d.joinpath("pending_control_requests.jsonl").stat().st_size > 0,
                30, "no pending control request buffered")
    h.send_keys(":llm-approve<ret>")
    h._wait_for(lambda: not d.joinpath("pending_control_requests.jsonl").exists()
                or d.joinpath("pending_control_requests.jsonl").stat().st_size == 0,
                5.0, "pending control-request buffer not cleared")
    # The shim continues streaming tokens; consume them then accept.
    h.stream_deltas(dir_path)
    h._wait_for_draft_active()
    h._wait_for(lambda: h._has_line("draw_status"), 2.0, "UI not responsive")
    h.send_keys(":llm-accept<ret>")
    h._wait_for(lambda: not h._has_line("llm_draft_active"), 5.0, "draft still active")
    # Flush committed ghost text to disk before quit (see scenario_accept).
    h.send_keys(":write!<ret>")
    h.send_keys(":quit!<ret>")
    h._wait_for(lambda: h.proc is not None and h.proc.poll() is not None, 15,
                "kak did not quit")
    expected = "".join(tokens) + base
    actual = read_target(target)
    if actual != expected:
        return False, f"buffer mismatch after control round-trip\n  expected={expected!r}\n  actual  ={actual!r}"
    return True, "control_request approval round-trip accepted tokens"


def scenario_stop(h: KakHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    """Stream tokens, then invoke real :llm-stop and verify cleanup."""
    dir_path = h.start_session(target, [])
    d = Path(dir_path)
    h.stream_deltas(dir_path)
    h._wait_for_draft_active()
    h._wait_for(lambda: h._has_line("draw_status"), 2.0, "UI not responsive")
    h.send_keys(":llm-stop<ret>")
    h._wait_for(lambda: not d.exists(), 5.0, "per-session dir not removed")
    return True, "llm-stop removed the per-session temp dir"


SCENARIOS = {
    "accept": scenario_accept,
    "reject": scenario_reject,
    "control": scenario_control,
    "stop": scenario_stop,
}


def main() -> int:
    parser = argparse.ArgumentParser(description="E2E harness driver")
    parser.add_argument("--scenario", default=os.environ.get("E2E_SCENARIO", "accept"),
                        choices=list(SCENARIOS.keys()))
    parser.add_argument("--tokens", default=os.environ.get("E2E_TOKENS", "Hello,world"),
                        help="Comma-separated tokens")
    parser.add_argument("--control-request", default=os.environ.get("E2E_CONTROL_REQUEST", ""),
                        help="Control request string")
    parser.add_argument("--delay", default=os.environ.get("E2E_DELAY", "0.05"),
                        help="Delay between tokens")
    parser.add_argument("--workdir", default=os.environ.get("E2E_WORKDIR"),
                        help="Working directory")
    args = parser.parse_args()
    scenario = args.scenario
    if scenario not in SCENARIOS:
        print(f"unknown scenario {scenario!r}; choose from {sorted(SCENARIOS)}",
              file=sys.stderr)
        return 2

    tokens = [t for t in args.tokens.split(",") if t != ""]
    control_request = args.control_request
    delay = args.delay

    if args.workdir:
        workdir = Path(args.workdir)
        workdir.mkdir(parents=True, exist_ok=True)
    else:
        workdir = Path(tempfile.mkdtemp(prefix=f"e2e-{scenario}-"))
    target = workdir / "target.txt"
    target.write_text("hello\nworld\n")

    harness = KakHarness(f"e2e-{os.getpid()}", workdir)
    # The shim reads its configuration from argv (--tokens/--delay/--control-request),
    # so wire everything through the -str-list llm_args option instead of env vars.
    # Tokens must reach the shim as *separate* argv elements (`--tokens`, `Hello,world`),
    # never in `--tokens=...` form: the shim uses exact-case matches on each argument,
    # so the equals-form is treated as a stray unknown flag.
    llm_args = ["--tokens"] + tokens + ["--delay", delay]
    if control_request:
        llm_args += ["--control-request", control_request]
    try:
        harness.start()
        # Source llm.kak pointing at our deterministic shim, passing the shim's
        # argv config via llm_args and pointing llm_cmd at the shim itself.
        harness._source(LLM_KAK, llm_args, shim=SHIM)
        ok, detail = SCENARIOS[scenario](harness, target, tokens)
        status = "PASS" if ok else "FAIL"
        print(f"{status}: {scenario} — {detail}")
        return 0 if ok else 1
    finally:
        harness.kill()
        harness.close()


if __name__ == "__main__":
    raise SystemExit(main())
