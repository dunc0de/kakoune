import contextlib
import json
import threading
import time
from collections.abc import Callable


class JsonRpcClient:
    """JSON-RPC client over kak stdin/stdout with condition variable waits."""

    def __init__(self, proc):
        self.proc = proc
        self._lines = []
        self._lock = threading.Lock()
        self._cond = threading.Condition(self._lock)
        self._stdin_lock = threading.Lock()
        self._stop = False
        self._drain_thread = threading.Thread(target=self._drain, daemon=True)
        self._drain_thread.start()

    def _drain(self):
        # Drain both stdout and stderr; Kakoune -ui json writes JSON-RPC on stdout
        # and status surface on stderr. Condition notifies waiters for predicate waits.
        with contextlib.suppress(Exception):
            out = self.proc.stdout
            if out:
                for line in out:
                    line = line.rstrip(b"\r\n")
                    if line:
                        with self._cond:
                            self._lines.append(line)
                            self._cond.notify_all()
            err = self.proc.stderr
            if err:
                for line in err:
                    line = line.rstrip(b"\r\n")
                    if line:
                        with self._cond:
                            self._lines.append(line)
                            self._cond.notify_all()

    def send_keys(self, chars: str) -> None:
        payload = json.dumps({"jsonrpc": "2.0", "method": "keys", "params": [chars]}) + "\n"
        with self._stdin_lock:
            if self.proc.stdin:
                self.proc.stdin.write(payload.encode())
                self.proc.stdin.flush()

    def _lines_text(self) -> str:
        with self._lock:
            return b"".join(self._lines).decode("latin-1")

    def wait_for(self, predicate: Callable[[], bool], timeout: float, message: str) -> None:
        # Condition wait avoids busy-loop and unblocks when _drain appends lines.
        deadline = time.monotonic() + timeout
        while True:
            if predicate():
                return
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(message)
            with self._cond:
                self._cond.wait(remaining)

    def has_line(self, needle: str) -> bool:
        return needle in self._lines_text()

    def close(self) -> None:
        with contextlib.suppress(Exception):
            if self.proc.stdout:
                self.proc.stdout.close()
        with contextlib.suppress(Exception):
            if self.proc.stderr:
                self.proc.stderr.close()
