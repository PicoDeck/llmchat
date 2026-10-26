#!/usr/bin/env python3
"""Record a real API reply as a test fixture.

    tools/record_stream.py <anthropic|opencode|openrouter|vercel> <case> [--dry-run]

Cases:
  anthropic (or claude): text, thinking, maxtokens, title, 401.
  opencode, openrouter, vercel (Chat Completions): text, reasoning, length,
    title, 401.

Keys are read only from ~/.config/llmchat/keys.txt, one `name=value` line per
service (the Anthropic key is the `claude=` line), and are never printed; a
keys file that other users can read or write is refused. The 401 case sends
a made-up key instead. --dry-run prints the request (URL, headers with the
key replaced by <key>, body) and sends nothing.

The raw response is saved to tests/fixtures/<service>-<case>.sse (or .json
for title and 401; an error reply gets a leading `#status N` line).
Anthropic recordings keep their `claude-` names. Ids are scrubbed:
msg_/resp_/req_/rs_/fc_/item_ ids become <prefix>_fixture, chatcmpl-/gen-
ids and the values of id-like keys become fixture, and sk-... strings are
removed. Usage and cost are appended to docs/research/api-spend.md: the
gateways report the cost themselves (usage.cost, plus the upstream cost of
a request that ran on the owner's own provider key); the others are priced
from the spec's tables. A new log gets its table header first; an error
reply is not billed, and gets a row with its status and $0.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
SPEND = os.path.join(ROOT, "docs", "research", "api-spend.md")
KEYS = os.path.expanduser("~/.config/llmchat/keys.txt")

SYSTEM = "You are a concise assistant. Keep answers short."
TITLE_PROMPT = ("Write a title of 2 to 5 words for this chat. Reply with the title only.\n\n"
                "how many cups in a litre?\n\nA litre is about 4.2 cups.")
QUESTION = "In one sentence: why is the sky blue?"
MATH = "What is 17*23? Think it through."

# $/MTok in, out (spec 6.2, 6.3)
PRICES = {
    "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10),
    "claude-haiku-5-5": (0.10, 0.50), "claude-fable-5-1": (10, 50),
}


def claude_request(case):
    url = "https://api.anthropic.com/v1/messages"
    headers = {"content-type": "application/json", "x-api-key": "<key>",
               "anthropic-version": "2026-10-21"}
    body = {"model": "claude-opus-5-5", "max_tokens": 32000, "stream": True,
            "cache_control": {"type": "ephemeral"}, "system": SYSTEM,
            "output_config": {"effort": "low"},
            "messages": [{"role": "user", "content": QUESTION}]}
    if case == "thinking":
        body["model"] = "claude-haiku-5-5"
        body["output_config"] = {"effort": "high"}
        body["messages"] = [{"role": "user", "content": MATH}]
    elif case == "maxtokens":
        body["max_tokens"] = 20
    elif case == "title":
        body = {"model": "claude-haiku-5-5", "max_tokens": 200,
                "output_config": {"effort": "low"},
                "messages": [{"role": "user", "content": TITLE_PROMPT}]}
    elif case == "401":
        body["max_tokens"] = 20
    elif case != "text":
        raise SystemExit("unknown claude case: " + case)
    if case in ("text", "thinking", "maxtokens", "401") and body["model"] != "claude-haiku-5-5":
        # Opus 5.5 / Sonnet 5.5 / Fable 5.1 get server-side fallback (spec 6.2)
        body["fallbacks"] = "default"
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    return url, headers, body




# Chat Completions gateways (gateways spec 4, 6.1): URL, effort field, model.
GATEWAYS = {
    "opencode": ("https://opencode.ai/inference/openai/v1/chat/completions", "reasoning_effort",
                 "deepseek-v4.1-flash"),
    "openrouter": ("https://openrouter.ai/api/v1/chat/completions", "reasoning",
                   "deepseek/deepseek-v4.1-flash-1017"),
    "vercel": ("https://ai-gateway.vercel.sh/v1/chat/completions", "reasoning",
               "deepseek/deepseek-v4.1-flash-1017"),
}
# The firmware's own User-Agent: Cloudflare in front of opencode.ai answers
# urllib's default with a 403 page (docs/research/2026-10-26-gateways-verify-first.md).
USER_AGENT = "PicoDeck/1.0"
BAD_KEY = "bad-key-for-recording"


def cc_request(service, case):
    url, field, model = GATEWAYS[service]

    def effort(e):
        return {field: e} if field == "reasoning_effort" else {field: {"effort": e}}
    headers = {"Authorization": "Bearer <key>", "Content-Type": "application/json",
               "Accept": "text/event-stream", "User-Agent": USER_AGENT}
    body = {"model": model, "stream": True, "stream_options": {"include_usage": True},
            "messages": [{"role": "system", "content": SYSTEM},
                         {"role": "user", "content": QUESTION}]}
    body.update(effort("low"))
    if case == "reasoning":
        body["messages"][1]["content"] = MATH
        body.update(effort("high"))
    elif case == "length":
        body["max_tokens"] = 40
    elif case == "title":
        del headers["Accept"]
        body = {"model": model, "max_tokens": 300,
                "messages": [{"role": "user", "content": TITLE_PROMPT}]}
        body.update(effort("low"))
    elif case not in ("text", "401"):
        raise SystemExit("unknown %s case: %s" % (service, case))
    return url, headers, body


def build(provider, case):
    if provider in ("claude", "anthropic"):
        return claude_request(case)
    if provider in GATEWAYS:
        return cc_request(provider, case)
    raise SystemExit("service must be anthropic, opencode, openrouter or vercel")


def shown(path):
    """path as the owner would type it: the home directory as ~."""
    home = os.path.expanduser("~")
    if path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path


def load_key(provider):
    try:
        with open(KEYS) as f:
            # Checked on the open file, before any of it is read.
            if os.fstat(f.fileno()).st_mode & 0o066:
                raise SystemExit("%s can be read or written by other users; run: chmod 600 %s"
                                 % (shown(KEYS), shown(KEYS)))
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    if k.strip() == provider and v.strip():
                        return v.strip()
    except OSError:
        pass
    raise SystemExit("no %s key in %s" % (provider, KEYS))


# An id is its prefix and letters and digits, a digit among them (rs_, fc_
# and item_ ids, from the old OpenAI recordings, as well): the API's own
# names that start the same way, such as item_id and item_reference, have none.
ID = re.compile(r"\b(msg|resp|req|rs|fc|item)_(?=[A-Za-z0-9]*[0-9])[A-Za-z0-9]+")
# Chat Completions chunk ids, and Vercel's routing ids.
CC_ID = re.compile(r"\b(chatcmpl|gen)-[A-Za-z0-9_\-]+")
ID_KEYS = re.compile(r'"(id|generationId|providerRequestId|providerResponseId|clientSessionId)":"(?![^"]*fixture")[^"]*"')


def scrub(text):
    text = ID.sub(r"\1_fixture", text)
    text = CC_ID.sub(r"\1-fixture", text)
    text = ID_KEYS.sub(r'"\1":"fixture"', text)
    return re.sub(r"sk-[A-Za-z0-9_\-]+", "<removed>", text)


def post(provider, case, key):
    url, headers, body = build(provider, case)
    headers = {k: v.replace("<key>", key) for k, v in headers.items()}
    req = urllib.request.Request(url, json.dumps(body).encode(), headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, r.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


def usage_of(provider, text):
    """(input_tokens, output_tokens, model, cost) from a saved reply. cost is
    the reply's own (the gateways' usage.cost), or None to price it here."""
    inp = out = 0
    model = ""
    cost = None
    if text.lstrip().startswith("{"):
        objs = [json.loads(text)]
    else:
        objs = [json.loads(m) for m in re.findall(r"^data: (\{.*\})$", text, re.M)]
    for o in objs:
        r = o.get("message") or o.get("response") or o
        model = r.get("model", model) if isinstance(r, dict) else model
        for u in (r.get("usage") if isinstance(r, dict) else None), o.get("usage"):
            if isinstance(u, dict):
                inp = u.get("input_tokens", u.get("prompt_tokens", inp)) or inp
                out = u.get("output_tokens", u.get("completion_tokens", out)) or out
                if "cost" in u:
                    cost = float(u.get("cost") or 0)
                    if u.get("is_byok"):
                        cost += float((u.get("cost_details") or {}).get("upstream_inference_cost") or 0)
    return inp, out, model, cost


SPEND_HEADER = ("# API spend\n\n"
                "Written by tools/record_stream.py, a row per request. An error reply is not billed.\n\n"
                "| case | status | model | in | out | cost |\n"
                "|---|---|---|---|---|---|\n")


def log_spend(provider, case, status, text):
    if status == 200:
        try:
            inp, out, model, cost = usage_of(provider, text)
        except (ValueError, KeyError):
            return
        if cost is None:
            pin, pout = PRICES.get(model, (0, 0))
            cost = (inp * pin + out * pout) / 1e6
    else:
        inp, out, model, cost = 0, 0, "-", 0
    os.makedirs(os.path.dirname(SPEND), exist_ok=True)
    new = not os.path.exists(SPEND) or os.path.getsize(SPEND) == 0
    with open(SPEND, "a") as f:
        if new:
            f.write(SPEND_HEADER)
        f.write("| %s-%s | %d | %s | %d | %d | $%.4f |\n" % (provider, case, status, model, inp, out, cost))
    if status == 200:
        print("spend: $%.4f (%d in, %d out, %s)" % (cost, inp, out, model))
    else:
        print("spend: $0 (HTTP %d: not billed)" % status)


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    dry = "--dry-run" in argv
    if len(args) != 2:
        raise SystemExit(__doc__)
    provider, case = args
    if provider == "anthropic":
        provider = "claude"  # the key line and the fixture names
    url, headers, body = build(provider, case)
    if dry:
        print("POST " + url)
        for k, v in headers.items():
            print("%s: %s" % (k, v))
        print(json.dumps(body, indent=2))
        return
    key = BAD_KEY if case == "401" else load_key(provider)
    status, text = post(provider, case, key)
    text = scrub(text.replace(key, "<removed>"))
    is_json = case in ("title", "401")
    name = "%s-%s.%s" % (provider, case, "json" if is_json else "sse")
    head = "#status %d\n" % status if status != 200 else ""
    with open(os.path.join(FIXTURES, name), "w") as f:
        f.write(head + text)
    print("saved %s (HTTP %d, %d bytes)" % (name, status, len(text)))
    log_spend(provider, case, status, text)


if __name__ == "__main__":
    main(sys.argv[1:])
