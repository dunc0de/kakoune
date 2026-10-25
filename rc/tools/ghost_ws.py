#!/usr/bin/env python3
# ghost_ws.py — detached WebSocket tailer for the ghost module (rc/tools/ghost.kak).
#
# Python 3 stdlib only (socket, base64, hashlib, json, selectors, signal,
# struct, subprocess) -- no installs. Launched detached by the ghost-session
# command (rc/tools/ghost.kak) with these environment variables:
#
#   GHOST_WS_URL          required; ws://host:port/path of the ghost-text bridge
#   GHOST_SESSION_ID      required; bridge session id (carried in every frame)
#   GHOST_DIR             optional; scratch dir; the control file is
#                         <GHOST_DIR>/control.jsonl (control polling no-ops
#                         when unset)
#   GHOST_CLIENT          optional; Kakoune client id for the -client dispatch
#                         target (dispatches omit -client when unset)
#   kak_session           required; Kakoune session name for `kak -p` dispatch
#   GHOST_WS_TIMEOUT      optional; seconds for connect/dispatch timeouts (default 5)
#   GHOST_WS_CONTROL_POLL optional; seconds between control-file polls (default 0.1)
#
# Wire contract (the ghost-text-agent bridge, RFC 6455 text frames):
#   S->C  {"type":"ghost_text","sessionId":<id>,"token":"<delta>"}
#   C->S  {"type":"user_control","sessionId":<id>,"control":"ACCEPT|REJECT|PAUSE|START|STOP"}
# On connect, the first client frame is a user_control START carrying
# GHOST_SESSION_ID; the bridge binds the channel to that session id there.
#
# For each ghost_text frame the tailer dispatches
#   `evaluate-commands -client <id> ghost-append-delta <base64(token)>`
# via `kak -p` (the engine in rc/tools/ghost.kak owns escaping/guard/insert).
# Lines of <GHOST_DIR>/control.jsonl (written by ghost-control) are shipped as
# user_control frames; a STOP line -- or SIGTERM -- ships a STOP frame, a WS
# close frame, and exits 0. A server close/EOF also exits 0 (clean teardown;
# the launcher's KakEnd hook / ghost-stop owns scratch-dir cleanup).
#
# Exit codes: 0 = clean (server close / STOP / SIGTERM); 1 = connect, protocol,
# or dispatch failure (e.g. the Kakoune session is dead); 2 = bad environment.

import base64
import hashlib
import json
import os
import selectors
import signal
import socket
import struct
import subprocess
import sys

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CONTROLS = ("ACCEPT", "REJECT", "PAUSE", "START", "STOP")


class Fatal(Exception):
    """Protocol/environment failure; main() exits 1."""


def parse_ws_url(url):
    """Parse a ws:// URL into (host, port, path). Only plaintext ws:// is
    supported -- wss:// (TLS) is out of scope for the local bridge."""
    if not url.startswith("ws://"):
        raise Fatal("only ws:// URLs are supported (got %r)" % url)
    rest = url[5:]
    hostport, _, path = rest.partition("/")
    path = "/" + path if path else "/"
    if ":" in hostport:
        host, port = hostport.rsplit(":", 1)
        return host, int(port), path
    return hostport, 80, path


def send_frame(sock, opcode, payload):
    """Client -> server frame, masked per RFC 6455 s5.3. A FRESH random 4-byte
    mask is drawn per frame -- never a static or zero mask (the CVE-2025-10148
    static-mask foot-gun)."""
    head = bytearray()
    head.append(0x80 | opcode)  # FIN=1
    n = len(payload)
    if n < 126:
        head.append(0x80 | n)
    elif n < (1 << 16):
        head.append(0x80 | 126)
        head += struct.pack(">H", n)
    else:
        head.append(0x80 | 127)
        head += struct.pack(">Q", n)
    key = os.urandom(4)
    head += key
    masked = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    sock.sendall(bytes(head) + masked)


class FrameReader:
    """Reads complete RFC 6455 messages from the server (server frames are
    UNMASKED per spec; a masked server frame is a protocol error). Continuation
    frames are reassembled so next_message() always yields one full message,
    even though the bridge only ever sends single-frame text."""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()
        self.frag_opcode = None
        self.frag = bytearray()

    def _fill(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("peer closed")
            self.buf.extend(chunk)

    def _read_frame(self):
        """Return (fin, opcode, payload) for the next raw frame."""
        self._fill(2)
        fin = bool(self.buf[0] & 0x80)
        opcode = self.buf[0] & 0x0F
        b1 = self.buf[1]
        if b1 & 0x80:
            raise Fatal("protocol error: server frames must not be masked")
        ln = b1 & 0x7F
        del self.buf[:2]  # consume the 2 header bytes (RFC 6455 §5.2)
        if ln == 126:
            self._fill(2)
            ln = struct.unpack(">H", bytes(self.buf[:2]))[0]
            del self.buf[:2]
        elif ln == 127:
            self._fill(8)
            ln = struct.unpack(">Q", bytes(self.buf[:8]))[0]
            del self.buf[:8]
        self._fill(ln)
        payload = bytes(self.buf[:ln])
        del self.buf[:ln]
        return fin, opcode, payload

    def next_message(self):
        """Return (opcode, payload) for the next complete message, reassembling
        continuation frames; control frames (8/9/A) are returned whole and may
        not interleave with a fragmented message."""
        while True:
            fin, opcode, payload = self._read_frame()
            if opcode in (0x8, 0x9, 0xA):
                if self.frag_opcode is not None:
                    raise Fatal("protocol error: control frame while fragmenting")
                return opcode, payload
            if opcode == 0x0:  # continuation
                if self.frag_opcode is None:
                    raise Fatal("protocol error: continuation without parent")
                self.frag.extend(payload)
                if fin:
                    full = bytes(self.frag)
                    parent = self.frag_opcode
                    self.frag_opcode, self.frag = None, bytearray()
                    return parent, full
                continue
            if fin:
                return opcode, payload
            self.frag_opcode, self.frag = opcode, bytearray(payload)


def handshake(sock, host, port, path):
    """Perform the RFC 6455 s4.1 client Upgrade and verify Sec-WebSocket-Accept."""
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    req = ("GET %s HTTP/1.1\r\n"
           "Host: %s:%d\r\n"
           "Upgrade: websocket\r\n"
           "Connection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\n"
           "Sec-WebSocket-Version: 13\r\n"
           "\r\n" % (path, host, port, key))
    sock.sendall(req.encode("ascii"))
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise Fatal("peer closed during handshake")
        data += chunk
    head, _, _ = data.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    if " 101 " not in lines[0] + " ":
        raise Fatal("handshake rejected: %s" % lines[0])
    expect = base64.b64encode(
        hashlib.sha1((key + WS_GUID).encode("ascii")).digest()).decode("ascii")
    got = ""
    for line in lines[1:]:
        name, _, value = line.partition(":")
        if name.strip().lower() == "sec-websocket-accept":
            got = value.strip()
    if got != expect:
        raise Fatal("bad Sec-WebSocket-Accept (got %r)" % got)


def main():
    url = os.environ.get("GHOST_WS_URL", "")
    session_id = os.environ.get("GHOST_SESSION_ID", "")
    kak_session = os.environ.get("kak_session", "")
    if not url or not session_id or not kak_session:
        sys.stderr.write(
            "ghost_ws.py: GHOST_WS_URL, GHOST_SESSION_ID and kak_session "
            "must all be set\n")
        return 2
    client = os.environ.get("GHOST_CLIENT", "")
    dir_ = os.environ.get("GHOST_DIR", "")
    control_path = os.path.join(dir_, "control.jsonl") if dir_ else ""
    timeout = float(os.environ.get("GHOST_WS_TIMEOUT", "5") or "5")
    poll = float(os.environ.get("GHOST_WS_CONTROL_POLL", "0.1") or "0.1")

    # Defined BEFORE the connect attempt: the handshake-failure path below
    # calls dispatch_stop(), and nested defs are not hoisted in Python.

    def dispatch_delta(b64):
        """Ship one token to the engine. b64 is [A-Za-z0-9+/=] only -- safe
        unquoted in the kak command line."""
        cmd = "evaluate-commands"
        if client:
            cmd += " -client %s" % client
        cmd += " ghost-append-delta %s\n" % b64
        try:
            subprocess.run(["kak", "-p", kak_session], input=cmd, text=True,
                           timeout=timeout, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        except (OSError, subprocess.SubprocessError) as e:
            raise Fatal("kak -p dispatch failed (session dead?): %s" % e)

    def dispatch_stop():
        """Ask the session to run ghost-stop so the scratch dir and state
        options are cleared when the tailer ends on its own (connect/handshake
        failure, server close, peer close, or a fatal dispatch error). The
        child runs in its OWN session (start_new_session) because ghost-stop
        process-group-kills the tailer -- which would otherwise kill the
        in-flight `kak -p` child before the command reaches the session. Never
        called on the STOP/SIGTERM path: that teardown is already owned by the
        caller (ghost-control STOP / ghost-stop), and re-dispatching from here
        would race it."""
        cmd = "evaluate-commands"
        if client:
            cmd += " -client %s" % client
        cmd += " ghost-stop\n"
        try:
            subprocess.run(["kak", "-p", kak_session], input=cmd, text=True,
                           timeout=timeout, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False,
                           start_new_session=True)
        except (OSError, subprocess.SubprocessError):
            pass  # session already gone; nothing left to clean

    try:
        host, port, path = parse_ws_url(url)
        sock = socket.create_connection((host, port), timeout=timeout)
        handshake(sock, host, port, path)
    except (Fatal, OSError) as e:
        sys.stderr.write("ghost_ws.py: connect/handshake failed: %s\n" % e)
        dispatch_stop()
        return 1
    sock.settimeout(None)  # blocking; the loop below drives cadence via select()

    def handle_text(payload):
        try:
            msg = json.loads(payload.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return
        if msg.get("type") != "ghost_text":
            return
        if msg.get("sessionId") != session_id:
            return  # defensive: single-client protocol; drop foreign sessions
        token = msg.get("token", "")
        dispatch_delta(base64.b64encode(token.encode("utf-8")).decode("ascii"))

    def poll_control(offset):
        """Ship new complete lines of the control file as user_control frames.
        Returns (new_offset, stop_requested)."""
        try:
            st = os.stat(control_path)
        except OSError:
            return offset, False
        if st.st_size < offset:
            offset = 0  # file truncated/rotated
        if st.st_size == offset:
            return offset, False
        with open(control_path, "rb") as f:
            f.seek(offset)
            data = f.read()
        end = data.rfind(b"\n")
        if end < 0:
            return offset, False
        chunk = data[:end + 1]
        offset += end + 1
        stop = False
        for line in chunk.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                ctrl = json.loads(line.decode("utf-8")).get("control", "")
            except (ValueError, UnicodeDecodeError):
                continue
            if ctrl not in CONTROLS:
                continue
            frame = json.dumps({"type": "user_control",
                                "sessionId": session_id,
                                "control": ctrl}).encode("ascii")
            send_frame(sock, 0x1, frame)
            if ctrl == "STOP":
                stop = True
        return offset, stop

    stopping = {"v": False}

    def on_term(signum, frame):
        stopping["v"] = True  # main loop notices within one poll interval

    signal.signal(signal.SIGTERM, on_term)

    reader = FrameReader(sock)
    # START bind: the first frame after the handshake -- the bridge binds the
    # channel to this session id there (see the wire contract above).
    send_frame(sock, 0x1, json.dumps(
        {"type": "user_control", "sessionId": session_id,
         "control": "START"}).encode("ascii"))

    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ)
    offset = 0
    try:
        while not stopping["v"]:
            # One select serves both as the cadence sleep (timeout=poll) and
            # the read-ready signal; the control file is polled every pass.
            events = sel.select(timeout=poll)
            offset, stop = poll_control(offset)
            if stop:
                break
            if not events:
                continue
            try:
                opcode, payload = reader.next_message()
                if opcode == 0x1:
                    handle_text(payload)
                elif opcode == 0x9:
                    send_frame(sock, 0xA, payload)  # pong: echo payload
                elif opcode == 0x8:
                    send_frame(sock, 0x8, struct.pack(">H", 1000))
                    dispatch_stop()
                    return 0  # server-initiated close: clean teardown
            except ConnectionError:
                dispatch_stop()
                return 0  # peer closed: clean teardown
    except Fatal as e:
        sys.stderr.write("ghost_ws.py: %s\n" % e)
        dispatch_stop()
        return 1

    # STOP (from the control file or SIGTERM): ship STOP + close, exit 0.
    try:
        send_frame(sock, 0x1, json.dumps(
            {"type": "user_control", "sessionId": session_id,
             "control": "STOP"}).encode("ascii"))
        send_frame(sock, 0x8, struct.pack(">H", 1000))
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
