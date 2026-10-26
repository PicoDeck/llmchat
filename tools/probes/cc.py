#!/usr/bin/env python3
"""One streaming Chat Completions request to a gateway, for the verify-first
questions (gateways spec section 11).

    python3 tools/probes/cc.py <opencode|openrouter|vercel> <model> [--long] [--effort low|medium|high|none]

Prints the HTTP status, the finish reason, the output and reasoning tokens,
the cost from usage.cost, and the reply's length; an error reply prints its
message. No max_tokens is sent. --long asks for a ~300-line program;
--effort none leaves the effort field out (default: low).

The key is read only from the service's line in ~/.config/llmchat/keys.txt,
which must not be readable by other users, and is never printed. Ids in the
output are scrubbed. Each request adds a row to docs/research/api-spend.md.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEND = os.path.join(ROOT, "docs", "research", "api-spend.md")
KEYS = os.path.expanduser("~/.config/llmchat/keys.txt")

SERVICES = {
    "opencode": ("https://opencode.ai/inference/openai/v1/chat/completions", "reasoning_effort"),
    "openrouter": ("https://openrouter.ai/api/v1/chat/completions", "reasoning"),
    "vercel": ("https://ai-gateway.vercel.sh/v1/chat/completions", "reasoning"),
}
SYSTEM = "You are a concise assistant. Keep answers short."
SHORT = "In one sentence: why is the sky blue?"
LONG = "Write a complete Lua program of about 300 lines: a Snake game for a 320x320 screen."


def load_key(service):
    try:
        with open(KEYS) as f:
            if os.fstat(f.fileno()).st_mode & 0o066:
                raise SystemExit("keys file can be read or written by other users; chmod 600 it")
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip() == service and v.strip():
                        return v.strip()
    except OSError:
        pass
    raise SystemExit("no %s key in the keys file" % service)


def scrub(text):
    text = re.sub(r'"(id|generationId)"\s*:\s*"[^"]*"', r'"\1":"<id>"', text)
    text = re.sub(r"\b(chatcmpl|gen)-[A-Za-z0-9_\-]+", r"\1-<id>", text)
    return re.sub(r"sk-[A-Za-z0-9_\-]+", "<removed>", text)


def body_for(service, model, long, effort):
    body = {"model": model, "stream": True, "stream_options": {"include_usage": True},
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": LONG if long else SHORT}]}
    if effort != "none":
        field = SERVICES[service][1]
        body[field] = effort if field == "reasoning_effort" else {"effort": effort}
    return body


def run(service, model, long, effort):
    url = SERVICES[service][0]
    key = load_key(service)
    body = body_for(service, model, long, effort)
    req = urllib.request.Request(url, json.dumps(body).encode(), {
        "Authorization": "Bearer " + key, "Content-Type": "application/json",
        "Accept": "text/event-stream",
        # The firmware's own (picodeck src/drivers/http.c). Cloudflare in
        # front of opencode.ai refuses urllib's default with a 403 page.
        "User-Agent": "PicoDeck/1.0"}, method="POST")
    t0 = time.monotonic()
    finish, usage, chars, err = None, {}, 0, None
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            status = r.status
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    o = json.loads(data)
                except ValueError:
                    continue
                if isinstance(o.get("error"), dict):
                    err = o["error"].get("message")
                for c in o.get("choices") or []:
                    d = c.get("delta") or {}
                    if isinstance(d.get("content"), str):
                        chars += len(d["content"])
                    if c.get("finish_reason"):
                        finish = c["finish_reason"]
                if isinstance(o.get("usage"), dict):
                    usage = o["usage"]
    except urllib.error.HTTPError as e:
        status = e.code
        err = scrub(e.read().decode("utf-8", "replace").replace(key, "<removed>"))[:400]
    secs = time.monotonic() - t0
    out = usage.get("completion_tokens", 0)
    reasoning = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0)
    cost = usage.get("cost") or 0
    print("status %d  finish %s  out %s  reasoning %s  cost $%.5f  chars %d  %.1f s"
          % (status, finish, out, reasoning, cost, chars, secs))
    if err:
        print("error:", err)
    case = "probe %s%s effort=%s" % (service, " long" if long else "", effort)
    with open(SPEND, "a") as f:
        f.write("| %s | %d | %s | %d | %d | $%.4f |\n"
                % (case, status, model, usage.get("prompt_tokens", 0), out, cost))


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    long = "--long" in argv
    effort = "low"
    if "--effort" in argv:
        i = argv.index("--effort")
        effort = argv[i + 1]
        args.remove(effort)
    if len(args) != 2 or args[0] not in SERVICES or effort not in ("low", "medium", "high", "none"):
        raise SystemExit(__doc__)
    run(args[0], args[1], long, effort)


if __name__ == "__main__":
    main(sys.argv[1:])
