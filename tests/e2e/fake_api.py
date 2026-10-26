"""A stand-in for the four services' APIs for simulator tests (one server:
the app's <service>_base overrides all point at it).

A POST is routed by its path to a service (SERVICES): Anthropic's Messages
API, or a gateway's Chat Completions. It replays
tests/fixtures/<prefix>-<name>.sse (or .hand.sse) for a streaming request,
where <name> comes from a last user message of the form "@<name>" (anything
else replays "text"), and <prefix>-title.json for a non-streaming one (the
title). Anthropic's fixtures are the claude-* ones. A fixture with a
"#status N" header line replies with that status. Leading ":" comment lines
are dropped.

"@prog-<name>" replies, in the service's stream format, with a short text and
a lua fence holding tests/fixtures/programs/<name>.lua (or prompt/<name>.lua
when that is missing).

A GET of a gateway's model list path serves tests/fixtures/lists/<service>.json.

    api = FakeAPI().start()
    api.url          http://127.0.0.1:<port>
    api.delay        seconds between 120-byte chunks of a stream (0 = none)
    api.requests     [{method, provider, stream, path, body, headers}, ...]
                     (provider: the service id)
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
PROMPT = Path(__file__).resolve().parents[2] / "prompt"
CHUNK = 120

# Chat path -> (service id, fixture prefix); list path -> service id.
SERVICES = {
    "/v1/messages": ("anthropic", "claude"),
    "/inference/openai/v1/chat/completions": ("opencode", "opencode"),
    "/api/v1/chat/completions": ("openrouter", "openrouter"),
    "/v1/chat/completions": ("vercel", "vercel"),
}
LISTS = {
    "/inference/v1/models": "opencode",
    "/api/v1/models?output_modalities=text": "openrouter",
    "/v1/models": "vercel",
}


def load_fixture(prefix, name, ext):
    """(status, body bytes) of tests/fixtures/<prefix>-<name>.<ext> (or the
    .hand.<ext> one), or None."""
    path = FIXTURES / f"{prefix}-{name}.{ext}"
    if not path.exists():
        path = FIXTURES / f"{prefix}-{name}.hand.{ext}"
    if not path.exists():
        return None
    lines = path.read_bytes().split(b"\n")
    while lines and lines[0].startswith(b":"):
        lines.pop(0)
    status = 200
    if lines and lines[0].startswith(b"#status "):
        status = int(lines.pop(0).split()[1])
    return status, b"\n".join(lines)


def program_source(name):
    """The text of program fixture <name>.lua, or None."""
    for path in (FIXTURES / "programs" / f"{name}.lua", PROMPT / f"{name}.lua"):
        if path.exists():
            return path.read_text()
    return None


def _sse(events):
    return "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events).encode()


def _pieces(text, size=200):
    return [text[i:i + size] for i in range(0, len(text), size)] or [""]


def claude_stream(text):
    """A Claude Messages stream whose reply is `text`."""
    events = [
        ("message_start", {"type": "message_start", "message": {
            "id": "msg_prog", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": [], "stop_reason": None, "usage": {"input_tokens": 10, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}}),
    ]
    for piece in _pieces(text):
        events.append(("content_block_delta", {"type": "content_block_delta", "index": 0,
                                               "delta": {"type": "text_delta", "text": piece}}))
    events += [
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                           "usage": {"output_tokens": 50}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    return _sse(events)


def cc_stream(text):
    """A Chat Completions stream whose reply is `text`."""
    def chunk(delta, finish=None, **extra):
        return {"id": "chatcmpl-prog", "object": "chat.completion.chunk", "model": "fake",
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}], **extra}
    out = [chunk({"role": "assistant", "content": ""})]
    out += [chunk({"content": piece}) for piece in _pieces(text)]
    out.append(chunk({}, "stop"))
    out.append({"id": "chatcmpl-prog", "object": "chat.completion.chunk", "choices": [],
                "usage": {"prompt_tokens": 10, "completion_tokens": 50, "cost": 0}})
    return ("".join(f"data: {json.dumps(c)}\n\n" for c in out) + "data: [DONE]\n\n").encode()


def program_reply(service, name):
    """(200, stream bytes) replying with program <name>, or None."""
    src = program_source(name)
    if src is None:
        return None
    if not src.endswith("\n"):
        src += "\n"
    text = f"Here is {name}.lua:\n\n```lua\n{src}```\n"
    return 200, (claude_stream(text) if service == "anthropic" else cc_stream(text))


def _text(content):
    if isinstance(content, str):
        return content
    return "".join(b.get("text", "") for b in content if isinstance(b, dict))


def last_user_text(body):
    """The text of the last user message in a Messages or Chat Completions body."""
    msgs = body.get("messages") or []
    if isinstance(msgs, str):
        return msgs
    for m in reversed(msgs):
        if isinstance(m, dict) and m.get("role") == "user":
            return _text(m.get("content", ""))
    return ""


class FakeAPI:
    def __init__(self):
        self.requests = []
        self.delay = 0.0
        self._server = None

    def start(self):
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, ctype, body):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    if ctype == "text/event-stream":
                        for i in range(0, len(body), CHUNK):
                            self.wfile.write(body[i:i + CHUNK])
                            self.wfile.flush()
                            if api.delay:
                                time.sleep(api.delay)
                    else:
                        self.wfile.write(body)
                except (ConnectionResetError, BrokenPipeError):
                    pass  # the app stopped or cancelled the request

            def do_GET(self):
                service = LISTS.get(self.path)
                api.requests.append(dict(method="GET", provider=service, stream=False, path=self.path,
                                         body=None, headers=dict(self.headers)))
                if not service:
                    return self._send(404, "text/plain", b"no list")
                self._send(200, "application/json", (FIXTURES / "lists" / f"{service}.json").read_bytes())

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                try:
                    body = json.loads(raw or b"{}")
                except ValueError:
                    body = {}
                service, prefix = SERVICES.get(self.path, (None, None))
                stream = bool(body.get("stream"))
                api.requests.append(dict(method="POST", provider=service, stream=stream, path=self.path,
                                         body=body, headers=dict(self.headers)))
                if not service:
                    return self._send(404, "text/plain", b"no such path")
                if stream:
                    text = last_user_text(body)
                    name = text[1:].strip() if text.startswith("@") else "text"
                    if name.startswith("prog-"):
                        found = program_reply(service, name[5:])
                    else:
                        found = load_fixture(prefix, name, "sse") or load_fixture(prefix, name, "json")
                else:
                    found = load_fixture(prefix, "title", "json")
                if found is None:
                    return self._send(404, "text/plain", b"no fixture")
                status, data = found
                ctype = "text/event-stream" if stream and status == 200 else "application/json"
                self._send(status, ctype, data)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    def stop(self):
        self._server.shutdown()
        self._server.server_close()
