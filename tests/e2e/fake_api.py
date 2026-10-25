"""A stand-in for the Claude and OpenAI APIs for simulator tests.

Replays tests/fixtures/<provider>-<name>.sse for a streaming request, where
<name> comes from a last user message of the form "@<name>" (anything else
replays "text"). A non-streaming request (the title) gets
<provider>-title.json. A fixture with a "#status N" header line replies with
that status. Leading ":" comment lines are dropped.

    api = FakeAPI().start()
    api.url          http://127.0.0.1:<port>
    api.delay        seconds between 120-byte chunks of a stream (0 = none)
    api.requests     [{provider, stream, path, body, headers}, ...]
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
CHUNK = 120


def load_fixture(provider, name, ext):
    """(status, body bytes) of tests/fixtures/<provider>-<name>.<ext>, or None."""
    path = FIXTURES / f"{provider}-{name}.{ext}"
    if not path.exists():
        return None
    lines = path.read_bytes().split(b"\n")
    while lines and lines[0].startswith(b":"):
        lines.pop(0)
    status = 200
    if lines and lines[0].startswith(b"#status "):
        status = int(lines.pop(0).split()[1])
    return status, b"\n".join(lines)


def _text(content):
    if isinstance(content, str):
        return content
    return "".join(b.get("text", "") for b in content if isinstance(b, dict))


def last_user_text(body):
    """The text of the last user message in a Messages or Responses body."""
    msgs = body.get("messages") or body.get("input") or []
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
                if ctype == "text/event-stream":
                    for i in range(0, len(body), CHUNK):
                        self.wfile.write(body[i:i + CHUNK])
                        self.wfile.flush()
                        if api.delay:
                            time.sleep(api.delay)
                else:
                    self.wfile.write(body)

            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                try:
                    body = json.loads(raw or b"{}")
                except ValueError:
                    body = {}
                provider = "openai" if "/responses" in self.path else "claude"
                stream = bool(body.get("stream"))
                api.requests.append(dict(provider=provider, stream=stream, path=self.path,
                                         body=body, headers=dict(self.headers)))
                if stream:
                    text = last_user_text(body)
                    name = text[1:].strip() if text.startswith("@") else "text"
                    found = load_fixture(provider, name, "sse") or load_fixture(provider, name, "json")
                else:
                    found = load_fixture(provider, "title", "json")
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
