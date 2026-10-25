"""Recent chats, Programs and Settings in the simulator."""
import json
import time

from conftest import APP
from test_chat import mark, no_lua_errors, shot, start_app, type_text, wait


# The simulator's clock starts at 2026-01-01 00:00 UTC.
SIM_NOW = 1767225600


def settled(sim, name):
    """A screenshot taken after a few: the first ones can be stale frames."""
    for _ in range(3):
        shot(sim, name)
        time.sleep(0.5)
    return shot(sim, name)


def seed_chats(data, now):
    """Two saved chats and their index (newest first)."""
    (data / "chats").mkdir(parents=True, exist_ok=True)
    rows = []
    for cid, title, provider, ago, n in (
        ("c1", "Cups in a litre", "claude", 120, 2),
        ("c2", "Fix my Python regex", "openai", 4 * 86400, 6),
    ):
        items = [{"role": "user" if i % 2 == 0 else "assistant", "text": f"line {i}"} for i in range(n)]
        chat = {"v": 1, "id": cid, "title": title, "provider": provider, "model": "m",
                "created": now - ago, "updated": now - ago, "items": items}
        (data / "chats" / f"{cid}.json").write_text(json.dumps(chat))
        rows.append({"id": cid, "title": title, "provider": provider, "model": "m",
                     "created": now - ago, "updated": now - ago, "count": n})
    (data / "chats" / "index.json").write_text(json.dumps(rows))


def test_open_a_chat_from_recent_chats(llmchat):
    sim, api, data = llmchat()
    seed_chats(data, SIM_NOW)
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    sim.keypress("f1")
    wait(sim, r"\[app\] screen lists", m)
    time.sleep(0.5)
    settled(sim, "recent-chats.png")
    sim.keypress("right")
    time.sleep(0.4)
    settled(sim, "programs-empty.png")
    sim.keypress("left")
    sim.keypress("down")
    m = mark(sim)
    sim.keypress("enter")
    wait(sim, r"\[app\] screen chat", m)
    time.sleep(0.5)
    settled(sim, "opened-chat.png")
    m = mark(sim)
    sim.keypress("f1")
    wait(sim, r"\[app\] screen lists", m)
    m = mark(sim)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)
    assert sim.is_alive()
    no_lua_errors(sim)


def test_set_a_key_in_settings(llmchat):
    sim, api, data = llmchat(keys=False)
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    sim.keypress("f5")
    wait(sim, r"\[app\] screen settings", m)
    time.sleep(0.5)
    shot(sim, "settings.png")
    for _ in range(3):  # Provider, Model, Claude key, OpenAI key
        sim.keypress("down")
        time.sleep(0.1)
    sim.keypress("enter")
    time.sleep(0.2)
    type_text(sim, "sk-e2e-0123456789")
    time.sleep(0.3)
    shot(sim, "settings-editing.png")
    sim.keypress("enter")
    time.sleep(0.5)
    shot(sim, "settings-masked.png")
    m = mark(sim)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)
    keys = (data / "keys.txt").read_text()
    assert "openai=sk-e2e-0123456789" in keys
    assert "sk-e2e-0123456789" not in "\n".join(l["text"] for l in sim.get_log_lines())
    assert (data / "prefs.json").exists()
    assert sim.is_alive()
    no_lua_errors(sim)
