#!/usr/bin/env python3
"""JSON emitter helper for mock-qwen.sh.

Centralizes JSON serialization and escaping to avoid shell quoting bugs.
"""
import json
import sys

def emit_event(f, event_type, data=None, **extra):
    # Centralises JSON emission to avoid shell quoting bugs; payload shape matches
    # mock-qwen.sh expectations: {"event":{"type":...}}.
    payload = {"event": {"type": event_type}}
    if data is not None:
        payload["event"]["data"] = data
    for k, v in extra.items():
        payload[k] = v
    line = json.dumps(payload, separators=(",", ":"))
    f.write(line + "\n")
    f.flush()

def emit_content_delta(f, text):
    # Emit with delta inside the event object as the real protocol expects.
    payload = {"event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}}
    line = json.dumps(payload, separators=(",", ":"))
    f.write(line + "\n")
    f.flush()

def escape_string(s: str) -> str:
    # Return JSON string literal without surrounding quotes, suitable for embedding
    # in a JSON string value. Using json.dumps gives properly escaped output.
    # Used to embed a Python string safely in a shell command line for mock-qwen.sh.
    return json.dumps(s)[1:-1]

if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "escape":
        # Print escaped string for shell consumption
        print(escape_string(sys.argv[2]))
    elif len(sys.argv) >= 3 and sys.argv[1] == "emit":
        event_type = sys.argv[2]
        if event_type == "session_start":
            emit_event(sys.stdout, "session_start", data={"supported_events":["control_request"]})
        elif event_type == "content_delta":
            text = sys.argv[3] if len(sys.argv) > 3 else ""
            emit_content_delta(sys.stdout, text)
        elif event_type == "control_request":
            request_id = sys.argv[3] if len(sys.argv) > 3 else ""
            emit_event(sys.stdout, "control_request", request_id=request_id)
        elif event_type == "llm_session_ended":
            emit_event(sys.stdout, "llm_session_ended")
        else:
            # Fallback: emit generic event
            emit_event(sys.stdout, event_type)
    else:
        # Simple CLI to emit a content delta to stdout
        text = sys.argv[1] if len(sys.argv) > 1 else ""
        emit_content_delta(sys.stdout, text)
