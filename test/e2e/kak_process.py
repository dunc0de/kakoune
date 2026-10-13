import contextlib
import os
import signal
import stat
import subprocess
from pathlib import Path


class KakProcess:
    """Spawn and manage a headless kak -ui json process with its own PGID."""

    def __init__(self, session: str, kak_bin: str, workdir: Path):
        self.session = session
        self.kak_bin = kak_bin
        self.workdir = Path(workdir)
        self.proc: subprocess.Popen | None = None

    def _socket_path(self) -> str:
        runtime = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
        return os.path.join(runtime, "kakoune", self.session)

    def _remove_stale_socket(self) -> None:
        # Remove stale socket left by SIGKILL'd Kakoune; otherwise next start fails
        # with "Address already in use".
        path = self._socket_path()
        with contextlib.suppress(OSError):
            if os.path.exists(path):
                mode = os.stat(path).st_mode
                if stat.S_ISSOCK(mode):
                    os.unlink(path)

    def start(self, extra_env: dict | None = None) -> None:
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        self._remove_stale_socket()
        # start_new_session=True gives the process its own PGID so kill() can killpg.
        self.proc = subprocess.Popen(
            [self.kak_bin, "-ui", "json", "-s", self.session, "-E", ""],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )

    def kill(self) -> None:
        if self.proc and self.proc.pid:
            with contextlib.suppress(ProcessLookupError, OSError):
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)

    def close(self) -> None:
        if self.proc and self.proc.stdin:
            with contextlib.suppress(OSError):
                self.proc.stdin.close()
        self._remove_stale_socket()
