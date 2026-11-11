"""The model picker and gateway chats in the simulator, against the fake API
(gateways spec 10): pick a model and send, the switch line, a gateway's
401, and an old Claude chat going on."""
import json
import time

from conftest import KEYS
from test_chat import mark, no_lua_errors, shot, start_app, type_text, wait
from test_programs import chat_files, launch, saved_text, send

LIST_GETS = ["/inference/v1/models", "/api/v1/models?output_modalities=text", "/v1/models"]


def pick(sim, text):
    """Opens the picker, waits for the lists, filters by `text` and picks the
    first match."""
    m = mark(sim)
    sim.keypress("f4")
    wait(sim, r"\[app\] screen picker", m)
    wait(sim, r"\[models\] vercel saved \d+ ids in \d+ ms", m)
    time.sleep(0.3)
    type_text(sim, text)
    time.sleep(0.4)
    m = mark(sim)
    sim.keypress("\n")
    wait(sim, r"\[app\] screen chat", m)
    time.sleep(0.3)


def test_pick_and_send(llmchat):
    sim, api, data = launch(llmchat)
    m = mark(sim)
    sim.keypress("f4")
    wait(sim, r"\[app\] screen picker", m)
    for svc in ("opencode", "openrouter", "vercel"):
        wait(sim, rf"\[models\] {svc} saved \d+ ids in \d+ ms", m)
    time.sleep(0.4)
    shot(sim, "picker.png")
    type_text(sim, "gemini")
    time.sleep(0.4)
    shot(sim, "picker-filter.png")
    m = mark(sim)
    sim.keypress("\n")
    wait(sim, r"\[app\] screen chat", m)
    prefs = json.loads((data / "prefs.json").read_text())
    assert prefs["model"] == "vercel/google/gemini-3.8-flash"
    assert prefs["recent"][0] == "vercel/google/gemini-3.8-flash"
    assert [r["path"] for r in api.requests if r["method"] == "GET"] == LIST_GETS
    for svc in ("opencode", "openrouter", "vercel"):
        assert (data / "models" / f"{svc}.txt").read_text().startswith("# fetched ")
    send(sim, "hi")
    streamed = [r for r in api.requests if r["stream"]]
    assert len(streamed) == 1
    assert streamed[0]["path"] == "/v1/chat/completions"
    assert streamed[0]["body"]["model"] == "google/gemini-3.8-flash"
    assert streamed[0]["body"]["reasoning"] == {"effort": "low"}
    assert streamed[0]["headers"].get("Authorization") == "Bearer " + KEYS["vercel"]
    chat = json.loads(chat_files(data)[0].read_text())
    reply = chat["items"][-1]
    assert reply["role"] == "assistant" and reply["provider"] == "vercel" and reply["text"]
    shot(sim, "gateway-reply.png")
    no_lua_errors(sim)


def test_switch_line(llmchat):
    sim, api, data = launch(llmchat)
    send(sim, "hi")  # a Claude reply
    pick(sim, "gemini")
    send(sim, "again")
    chat = json.loads(chat_files(data)[0].read_text())
    assert [i["role"] for i in chat["items"]] == ["user", "assistant", "note", "user", "assistant"]
    assert chat["items"][2] == {"role": "note", "kind": "model", "text": "now vercel/google/gemini-3.8-flash"}
    assert chat["items"][1]["provider"] == "anthropic" and chat["items"][4]["provider"] == "vercel"
    sent = [r for r in api.requests if r["stream"]][-1]
    assert "now vercel" not in json.dumps(sent["body"]), "the switch note was sent"
    # the switch line's two rules, rgb(85,85,85) (in RGB565 on screen), on one row
    from PIL import Image

    def rule(p):
        return all(abs(c - 85) <= 6 for c in p)
    found = False
    for _ in range(10):
        im = Image.open(shot(sim, "switch-line.png")).convert("RGB")
        for y in range(30, 268):
            left = sum(1 for x in range(14, 60) if rule(im.getpixel((x, y))))
            right = sum(1 for x in range(260, 306) if rule(im.getpixel((x, y))))
            if left > 30 and right > 30:
                found = True
                break
        if found:
            break
        time.sleep(0.3)
    assert found, "the switch line's rules"
    no_lua_errors(sim)


def test_gateway_401(llmchat):
    sim, api, data = launch(llmchat, model="vercel/google/gemini-3.8-flash")
    m = mark(sim)
    type_text(sim, "@401")
    sim.keypress("\n")
    wait(sim, r"\[chat\] failed", m)
    assert "Vercel rejected the API key. Check Settings." in saved_text(data)
    assert len([r for r in api.requests if r["stream"]]) == 1, "a 401 is not sent again"
    no_lua_errors(sim)


def test_old_claude_chat(llmchat):
    """Gateways spec 7: a chat saved before the update goes on with its
    thinking history."""
    sim, api, data = llmchat()
    raw = [{"type": "thinking", "thinking": "", "signature": "sig-old"}, {"type": "text", "text": "b"}]
    chat = {"v": 1, "id": "old1", "title": "Old chat", "created": 1, "updated": 1,
            "provider": "claude", "model": "claude-opus-5-5", "items": [
                {"role": "user", "text": "a"},
                {"role": "assistant", "provider": "claude", "model": "claude-opus-5-5", "text": "b", "raw": raw}]}
    (data / "chats").mkdir(parents=True, exist_ok=True)
    (data / "chats" / "old1.json").write_text(json.dumps(chat))
    (data / "chats" / "index.json").write_text(json.dumps([{"id": "old1", "title": "Old chat", "created": 1,
        "updated": 1, "provider": "claude", "model": "claude-opus-5-5", "count": 2}]))
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    sim.keypress("f1")
    wait(sim, r"\[app\] screen lists", m)
    time.sleep(0.3)
    m = mark(sim)
    sim.keypress("enter")
    wait(sim, r"\[app\] screen chat", m)
    time.sleep(0.3)
    send(sim, "c")
    sent = [r for r in api.requests if r["stream"]][-1]
    assert sent["path"] == "/v1/messages"
    assert sent["body"]["messages"][1] == {"role": "assistant", "content": raw}
    saved = json.loads((data / "chats" / "old1.json").read_text())
    assert not any(i.get("kind") == "model" for i in saved["items"]), "a switch note on the same model"
    no_lua_errors(sim)
