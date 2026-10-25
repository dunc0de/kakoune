#!/usr/bin/env python3
"""End-to-end harness for the ghost WS plugin.

This is the first end-to-end exercise of the *real* tailer
(``rc/tools/ghost_ws.py``): a mock WebSocket bridge
(``ghost_ws_server.py``) plays the ghost-text-agent side, and the tailer's
``kak -p`` dispatches drive the real Kakoune buffer. The three scenarios cover
the bridge->tailer->kak TEXT path and the user-control channel:

* ``ws_accept`` -- the bridge->tailer->kak TEXT path (streamed tokens reach the
  buffer) AND the ``ghost-control ACCEPT`` round-trip (control.jsonl + the
  server receives a user_control frame carrying the bound sessionId).
* ``ws_reject`` -- the kak-side ``ghost-reject`` erases the span (buffer back
  to base) AND the ``ghost-control REJECT`` round-trip.
* ``ws_stop``   -- ``ghost-control STOP`` ships STOP to the bridge, closes the
  WS, and tears the session down (tailer process gone, scratch dir removed).

Reuse contract: process management, drain thread, JSON-RPC ``send_keys``, and
the ``%opt{}`` reader all come from :class:`e2e_driver.KakHarness`; the ghost
module is sourced by absolute path (the build-tree ``rc/tools/ghost.kak``, the
same source the built Kakoune ships).

State is read from the DISK and process table, not from Kakoune ``%opt{}``
round-trips: the ghost scratch dir (created under this process's TMPDIR), the
tailer PID (``pgrep`` on the resolved tailer path), and the sessionId (the
mock server's log). The llm harness found that ``%opt{}`` reads stall once a
delta is committed; the disk-side markers sidestep that entirely and are the
same signals the assertions ultimately care about.

Run via ``test/e2e/run-ghost.sh`` (locates ``src/kak`` and sets ``KAK_BIN``),
or directly with ``KAK_BIN`` exported.
"""

from __future__ import annotations

import contextlib
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
# KAK_BIN comes from the KAK_BIN env var. run-ghost.sh defaults it to the
# cwd-relative "src/kak", so run from the repo root (or export an absolute
# KAK_BIN); the import lets both harnesses honour the same resolution.
from e2e_driver import KakHarness, read_target, KAK_BIN

_HERE = Path(__file__).resolve().parent
# This file lives at <repo>/test/e2e/ghost_e2e.py, so the repo root is TWO
# levels up (mirrors e2e_driver._REPO_ROOT).
_REPO_ROOT = _HERE.parent.parent

GHOST_KAK = _REPO_ROOT / "rc" / "tools" / "ghost.kak"
GHOST_WS_PY = _REPO_ROOT / "rc" / "tools" / "ghost_ws.py"
GHOST_WS_SERVER = _HERE / "ghost_ws_server.py"

# Scripted bridge -> tailer token stream: "hi " is < 126 bytes (7-bit WS frame
# length), the 300-byte run is > 126 (16-bit length) -- both decode paths in
# the tailer's FrameReader are exercised. The buffer assertion is
# `"".join(TOKENS) + base`.
TOKENS = ["hi ", "L" * 300]

# Per-run marker derived from this process PID + timestamp so
# concurrent harness runs don't match each other's tailer PIDs.
GHOST_E2E_RUN_ID = f"ghost-e2e-{os.getpid()}-{int(time.time() * 1000)}"


class GhostHarness(KakHarness):
    """Kakoune harness pre-configured for the ghost WS plugin.

    ``start()`` is the only overridden behaviour: it sources ``ghost.kak``,
    points ``ghost_ws_py`` at the real ``rc/tools/ghost_ws.py`` (so the
    tailer path does not depend on ``%val{runtime}`` resolving into the
    repo tree), and spawns the mock WS bridge on a kernel-assigned loopback
    port. The ghost scratch dir is isolated by pointing the kak process's
    TMPDIR at this harness's workdir.
    """

    ws_proc: subprocess.Popen | None = None
    ws_port: int = 0
    ws_log: Path = Path("")
    tokens: list[str] = []

    def start(self, extra_env: dict[str, str] | None = None,
              ghost_args: list[str] | None = None) -> None:
        # Signature-compatible with KakHarness.start; both parameters are
        # ignored here (the ghost flow has no shim argv, and env is built
        # below with the TMPDIR isolation).
        # Isolate the ghost scratch dir: ghost-session does
        # `mktemp -d "${TMPDIR:-/tmp}"/kak-ghost.XXXXXXXX`, so pointing TMPDIR
        # at our workdir makes the dir unambiguously ours.
        self._remove_stale_socket()
        assert self._drain_thread is None and self.proc is None
        env = {**os.environ, "TMPDIR": str(self.workdir)}
        self.proc = subprocess.Popen(
            [KAK_BIN, "-ui", "json", "-s", self.session, "-E", ""],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True, env=env)
        self._drain_thread = threading.Thread(
            target=self._drain, daemon=True)
        self._drain_thread.start()
        self._wait_for(lambda: self._has_line("set_ui_options"), 15,
                       "no set_ui_options")
        # Source the ghost module (declares options/commands/hooks), then
        # point the tailer at the real script by absolute path.
        self.send_keys(f":source {GHOST_KAK}<ret>")
        time.sleep(0.3)
        # provide-module only registers the body on source; the option
        # declarations and command definitions run on require-module.
        self.send_keys(":require-module ghost<ret>")
        time.sleep(0.3)
        self.send_keys(f":set-option global ghost_ws_py {GHOST_WS_PY}<ret>")
        time.sleep(0.2)
        # Spawn the mock bridge on a kernel-assigned port; read the ACTUAL
        # port back from its LISTEN log line (no free-port race).
        self.ws_log = self.workdir / "ws.log"
        self.tokens = list(TOKENS)
        self.ws_proc = subprocess.Popen(
            [sys.executable, str(GHOST_WS_SERVER), "0", str(self.ws_log)],
            env={**os.environ, "GHOST_E2E_TOKENS": ",".join(self.tokens),
                 "GHOST_E2E_RUN_ID": GHOST_E2E_RUN_ID},
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        deadline = time.time() + 10
        while time.time() < deadline:
            port = _port_from_log(self.ws_log)
            if port:
                self.ws_port = port
                break
            time.sleep(0.1)
        assert self.ws_port, f"mock WS bridge never logged LISTEN ({self.ws_log})"

    def kill_server(self) -> None:
        with contextlib.suppress(Exception):
            if self.ws_proc is not None and self.ws_proc.poll() is None:
                self.ws_proc.terminate()
                with contextlib.suppress(subprocess.TimeoutExpired):
                    self.ws_proc.wait(timeout=2)
                if self.ws_proc.poll() is None:
                    self.ws_proc.kill()


# ---------------------------------------------------------------------------
# disk / process-table state helpers (no %opt{} round-trips)
# ---------------------------------------------------------------------------

def _port_from_log(path: Path) -> int:
    """Read the bound port from the mock server's LISTEN log line.

    Guard against partial/broken lines so a stale log file
    doesn't raise IndexError and kill the harness setup.
    """
    with contextlib.suppress(OSError):
        for line in path.read_text().splitlines():
            if line.startswith("LISTEN "):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        return int(parts[1])
                    except ValueError:
                        pass
    return 0


def _tailer_pids() -> list[str]:
    # Match on the per-run marker so concurrent harness runs
    # don't match each other's tailer PIDs.
    out = subprocess.run(
        ["pgrep", "-f", f"{GHOST_WS_PY}|{GHOST_E2E_RUN_ID}"],
        capture_output=True, text=True)
    return out.stdout.split()


def _find_ghost_dir(workdir: Path) -> Path | None:
    cands = sorted(workdir.glob("kak-ghost.*"),
                   key=lambda p: p.stat().st_mtime)
    for c in reversed(cands):  # newest first
        if (c / "control.jsonl").exists():
            return c
    return cands[-1] if cands else None


def _server_sid(harness: GhostHarness) -> str | None:
    with contextlib.suppress(OSError):
        for line in harness.ws_log.read_text().splitlines():
            if line.startswith("START "):
                return line.split(" ", 1)[1].strip()
    return None


def _wait_for_in_file(path: Path, needle: str, timeout: float) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        with contextlib.suppress(OSError):
            if needle in path.read_text():
                return
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {needle!r} in {path}")


def _wait_until(fn, timeout: float, message: str) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline and not fn():
        time.sleep(0.1)
    if not fn():
        raise AssertionError(message)


# ---------------------------------------------------------------------------
# shared scenario scaffolding
# ---------------------------------------------------------------------------

def _start_session(h: GhostHarness, target: Path) -> tuple[str, Path, str]:
    """Edit the target, start the ghost session, wait for the tailer + the
    first committed delta. Returns (tailer_pid, ghost_dir, session_id).

    ws_accept and ws_reject sleep 1.0s after _start_session so the full
    scripted token stream has committed before their buffer assertions;
    ws_stop does not (it asserts teardown, not buffer content).
    """
    h.send_keys(f":edit {target}<ret>")
    time.sleep(0.2)
    h.send_keys(f":ghost-session ws://127.0.0.1:{h.ws_port}/ws<ret>")
    # The tailer process appears as soon as ghost-session's %sh body launches
    # it (before its liveness check even finishes).
    _wait_until(lambda: _tailer_pids(), 10,
                "ghost tailer process never appeared (ghost-session failed?)")
    ghost_dir = _find_ghost_dir(h.workdir)
    assert ghost_dir, f"ghost scratch dir not found under {h.workdir}"
    # The first committed delta creates <ghost_dir>/pre.txt -- a disk-side
    # marker that needs no kak round-trip.
    pre = ghost_dir / "pre.txt"
    _wait_until(lambda: pre.exists(), 15,
                f"pre.txt never appeared under {ghost_dir} (tokens didn't commit)")
    sid = _server_sid(h)
    assert sid, "mock bridge never logged a START (channel not bound)"
    return _tailer_pids()[0], ghost_dir, sid


def _assert_buffer(h: GhostHarness, target: Path, expected: str,
                   label: str) -> tuple[bool, str]:
    h.send_keys(":write!<ret>")
    time.sleep(0.3)
    h.send_keys(":quit!<ret>")
    time.sleep(0.5)
    got = read_target(target)
    ok = got == expected
    return ok, (f"{label}: expected {len(expected)} bytes, got {len(got)}")


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

def ws_accept(h: GhostHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    base = read_target(target)
    _pid, ghost_dir, sid = _start_session(h, target)
    # Let the full scripted token stream land (2 tokens @ 0.1 s spacing; the
    # first delta is already committed when _start_session returns).
    time.sleep(1.0)
    # (a) The ACCEPT control round-trip -- must complete while kak is alive,
    # because ghost-control is a kak command and the tailer ships it from its
    # poll loop. control.jsonl carries it, then the bridge receives a
    # user_control frame carrying the bound sessionId.
    h.send_keys(":ghost-control ACCEPT<ret>")
    _wait_for_in_file(ghost_dir / "control.jsonl", '"control":"ACCEPT"', 10)
    _wait_for_in_file(h.ws_log, f'START {sid}', 10)
    _wait_for_in_file(h.ws_log, 'CONTROL ACCEPT', 10)
    # (b) The bridge->tailer->kak TEXT path: the streamed tokens are in the
    # buffer (the ghost text is inserted directly, so write! captures it).
    # write!+quit! terminates kak, so it runs LAST.
    ok, detail = _assert_buffer(h, target, "".join(tokens) + base, "accept")
    return ok, detail


def ws_reject(h: GhostHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    base = read_target(target)
    _pid, ghost_dir, sid = _start_session(h, target)
    # Let the full scripted token stream land (2 tokens @ 0.1 s spacing; the
    # first delta is already committed when _start_session returns).
    time.sleep(1.0)
    # (a) The kak-side DRAFT-MODE reject: `ghost-reject` erases the accumulated
    #     ghost span (start -> anchor) with one `execute-keys d`. The append-delta
    #     inserts via `execute-keys -draft`, so this exercises the guard
    #     (anchor != start) + the erase path in the faithful json-UI environment.
    h.send_keys(":ghost-reject<ret>")
    time.sleep(0.5)
    # (b) The REJECT control round-trip (kak command -> control.jsonl -> tailer
    #     -> WS frame -> bridge), asserted while kak is still alive. This is the
    #     WS wiring the e2e owns.
    h.send_keys(":ghost-control REJECT<ret>")
    _wait_for_in_file(ghost_dir / "control.jsonl", '"control":"REJECT"', 10)
    _wait_for_in_file(h.ws_log, f'START {sid}', 10)
    _wait_for_in_file(h.ws_log, 'CONTROL REJECT', 10)
    # (c) The buffer is back to base: the ghost span was erased by ghost-reject
    #     in (a). write!+quit! terminates kak, so it runs LAST.
    ok, detail = _assert_buffer(h, target, base, "reject-erase")
    return ok, detail


def ws_stop(h: GhostHarness, target: Path, tokens: list[str]) -> tuple[bool, str]:
    _pid, ghost_dir, sid = _start_session(h, target)
    # ghost-control STOP writes the control line AND calls ghost-stop, which
    # SIGTERMs the tailer; its SIGTERM handler ships STOP + closes the WS.
    h.send_keys(":ghost-control STOP<ret>")
    # (a) The bridge received STOP carrying the bound sessionId, then the WS
    # closed.
    _wait_for_in_file(h.ws_log, f'START {sid}', 10)
    _wait_for_in_file(h.ws_log, 'CONTROL STOP', 10)
    _wait_for_in_file(h.ws_log, "CLOSE-RECV", 10)
    # (b) The tailer process is gone and the scratch dir is removed.
    _wait_until(lambda: not _tailer_pids(), 10, "ghost tailer still alive after STOP")
    _wait_until(lambda: not ghost_dir.exists(), 10,
                f"ghost scratch dir {ghost_dir} not removed after STOP")
    # End kak cleanly (no buffer assertion -- the draft was torn down).
    h.send_keys(":quit!<ret>")
    time.sleep(0.5)
    return True, "stop: control STOP + CLOSE-RECV seen; tailer gone; dir removed"


SCENARIOS = {
    "ws_accept": ws_accept,
    "ws_reject": ws_reject,
    "ws_stop": ws_stop,
}


def main(argv: list[str]) -> int:
    scenario = argv[1] if len(argv) > 1 else "ws_accept"
    if scenario not in SCENARIOS:
        sys.stderr.write(f"unknown scenario: {scenario}\n")
        return 2
    workdir = Path(tempfile.mkdtemp(prefix="ghost-e2e-"))
    target = workdir / "target.txt"
    target.write_text("hello\nworld\n")
    harness = GhostHarness(
        session=f"e2e-ghost-{os.getpid()}", workdir=workdir)
    try:
        harness.start()
        ok, detail = SCENARIOS[scenario](harness, target, harness.tokens)
        print(("PASS" if ok else "FAIL") + f": {scenario} \u2014 {detail}")
        return 0 if ok else 1
    except Exception as exc:  # noqa: BLE001 - report any scenario crash
        import traceback
        traceback.print_exc()
        print(f"FAIL: {scenario} \u2014 exception: {exc}")
        return 1
    finally:
        # Best-effort ghost session teardown while kak is still alive, then
        # hard-kill the kak process group, any lingering tailer, and the mock
        # bridge. The tailer is setsid'd into its own group, so harness.kill()
        # (kak's pgid) does not reach it -- kill it explicitly.
        with contextlib.suppress(Exception):
            harness.send_keys(":ghost-stop<ret>")
            time.sleep(0.5)
        harness.kill()
        subprocess.run(["pkill", "-9", "-f", str(GHOST_WS_PY)],
                       capture_output=True)
        harness.kill_server()
        harness.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
