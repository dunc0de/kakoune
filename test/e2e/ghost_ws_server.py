#!/usr/bin/env python3
"""Mock WebSocket bridge for the ghost e2e harness (ghost_e2e.py).

The real ghost-text-agent bridge is a Flink/OpenAI service; this stub stands in
for the slice the harness actually proves -- the WS channel + the bridge-side
protocol -- so the *real* tailer (rc/tools/ghost_ws.py) can be exercised
end-to-end without a running bridge. It is kept in sync with the tailer's codec:

* the RFC 6455 handshake the tailer's ``handshake()`` VERIFIES -- the reply must
  carry a correct ``Sec-WebSocket-Accept`` (sha1 of key + the magic GUID,
  base64). A wrong Accept makes the tailer abort before sending START.
* UNMASKED server -> client frames (the tailer's FrameReader rejects a masked
  server frame as a protocol error).
* masked client -> server frames are unmasked on read (client frames always
  carry a 4-byte mask per RFC 6455 s5.3).
* the 7-bit AND 16-bit frame-length paths are both exercised -- the default
  token set is ``["hi ", "L"*300]``: the first ghost_text frame is < 126 bytes
  (7-bit length), the second is > 126 (16-bit length), matching the bridge
  frame shapes the tailer's FrameReader must decode.

Protocol the tailer (and hence the bridge) uses -- this mirrors the REAL
rc/tools/ghost_ws.py exactly (its header's "Wire contract" block):

* client -> server: every frame is a ``{"type":"user_control",...}`` object.
  On connect the tailer's FIRST frame is
  ``{"type":"user_control","sessionId":<sid>,"control":"START"}``; each later
  control is the same shape with ``control`` = ACCEPT/REJECT/PAUSE/START/STOP.
  (There is no separate ``{"type":"start"}`` frame -- START is a user_control.)
* server -> client: ``{"type":"ghost_text","sessionId":<sid>,"token":<str>}``
  frames, streamed in response to the START control.

The server accepts ONE connection (one ghost session per run), then exits when
the tailer closes. It logs lifecycle lines to ``<log_file>`` -- the harness's
assertions read that file rather than parsing kak's output, because the tailer
drives kak via ``kak -p`` (a separate IPC) whose output does not land in the
harness's capture.

Usage:  ghost_ws_server.py <port> <log_file>
Env:    GHOST_E2E_TOKENS  comma-separated token list to emit on START
                (default "hi ,LLL...300"; the space is significant).
"""

import base64
import json
import os
import select
import socket
import struct
import sys
import time

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def log(logf, msg):
    line = msg + "\n"
    logf.write(line)
    logf.flush()
    sys.stderr.write(line)


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("peer closed")
        data += chunk
    return data


def read_msg(sock):
    """Read one WS message (client frames are masked). Returns (opcode,
    payload) with the unmasked payload bytes. Raises ConnectionError if the
    peer closed. The close frame (opcode 0x8) carries a 2-byte status code, not
    JSON -- the caller must branch on opcode before json-parsing the payload."""
    h = read_exact(sock, 2)
    b0 = h[0]
    b1 = h[1]
    opcode = b0 & 0x0F
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", read_exact(sock, 2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", read_exact(sock, 8))[0]
    mask = read_exact(sock, 4) if b1 & 0x80 else None
    payload = bytearray(read_exact(sock, ln))
    if mask:
        for i in range(len(payload)):
            payload[i] ^= mask[i % 4]
    return opcode, bytes(payload)


def send_text(sock, s):
    data = s.encode()
    hdr = bytearray([0x81])  # FIN + text, UNMASKED (server frame)
    n = len(data)
    if n < 126:
        hdr.append(n)
    elif n < 65536:
        hdr.append(126)
        hdr += struct.pack(">H", n)
    else:
        hdr.append(127)
        hdr += struct.pack(">Q", n)
    sock.sendall(bytes(hdr) + data)


def handshake_reply(sock, req_bytes, logf):
    """Verify the request carries Sec-WebSocket-Key, then reply 101 with the
    correct Sec-WebSocket-Accept -- the tailer recomputes and compares it and
    aborts on mismatch."""
    key = None
    for line in req_bytes.decode("latin-1").split("\r\n"):
        if line.lower().startswith("sec-websocket-key:"):
            key = line.split(":", 1)[1].strip()
    if key is None:
        log(logf, "NO-KEY")
        sock.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        return False
    # RFC 6455 requires SHA-1 for WebSocket accept
    _sha1 = __import__('hashlib').sha1
    sha = _sha1((key + WS_GUID).encode()).digest()
    accept = base64.b64encode(sha).decode()
    sock.sendall(
        ("HTTP/1.1 101 Switching Protocols\r\n"
         "Upgrade: websocket\r\n"
         "Connection: Upgrade\r\n"
         f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
    log(logf, f"HANDSHAKE {key}")
    return True


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: ghost_ws_server.py <port> <log_file>\n")
        return 2
    port = int(sys.argv[1])
    log_path = sys.argv[2]
    tokens = os.environ.get("GHOST_E2E_TOKENS")
    if tokens is None:
        tokens = "hi ," + "L" * 300
    tokens = [t for t in tokens.split(",") if t != ""]
    if not tokens:
        tokens = ["hi ", "L" * 300]

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # port 0 lets the kernel assign a free port (race-free); we report the
    # ACTUAL bound port on the LISTEN line for the harness to read.
    srv.bind(("127.0.0.1", port))
    actual = srv.getsockname()[1]
    srv.listen(1)
    logf = open(log_path, "w", encoding="utf-8")
    # GHOST_E2E_RUN_ID identifies the harness run in the log lines.
    run_id = os.environ.get("GHOST_E2E_RUN_ID", "")
    log(logf, f"LISTEN {actual} tokens={len(tokens)} run_id={run_id}")
    # Init conn to None so the finally block can safely close it.
    conn = None
    try:
        conn, _ = srv.accept()
        # Read the HTTP upgrade request through the first blank line.
        req = b""
        while b"\r\n\r\n" not in req:
            chunk = conn.recv(4096)
            if not chunk:
                break
            req += chunk
        if not handshake_reply(conn, req, logf):
            conn.close()
            return 1
        sid = None
        # Drive the loop with select so the token-emit delays do not block the
        # control/close reads (the tailer keeps the socket open while it polls
        # the control file).
        while True:
            try:
                r, _, _ = select.select([conn], [], [], 1.0)
            except OSError:
                break
            if not r:
                continue  # nothing to read this tick; keep serving
            try:
                opcode, msg = read_msg(conn)
            except ConnectionError:
                log(logf, "CLOSE-RECV")
                break
            if opcode == 0x8:  # client WS close frame (status code, not JSON)
                log(logf, "CLOSE-RECV")
                break
            if not msg:
                continue
            # Guard json.loads so malformed/binary frames don't
            # kill the mock server out of the loop.
            try:
                obj = json.loads(msg.decode())
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                log(logf, f"BAD-JSON {e}")
                break
            t = obj.get("type")
            control = obj.get("control")
            if t == "user_control":
                if control == "START":
                    sid = obj.get("sessionId")
                    log(logf, f"START {sid} run_id={run_id}")
                    # Emit the scripted ghost_text frames, one per token, with
                    # a small gap so the tailer's dispatches (kak -p per delta)
                    # are observable as distinct events.
                    for tok in tokens:
                        send_text(conn, json.dumps(
                            {"type": "ghost_text", "sessionId": sid,
                             "token": tok}))
                        log(logf, f"tok {len(tok)}B")
                        time.sleep(0.1)
                else:
                    log(logf, f"CONTROL {control}")
            else:
                log(logf, f"OTHER {json.dumps(obj)}")
    finally:
        # Always close conn (initialized to None above), logf, srv.
        if conn is not None:
            conn.close()
        log(logf, "CLOSE")
        logf.close()
        srv.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
