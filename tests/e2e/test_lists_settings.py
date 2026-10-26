"""Recent chats, Programs and Settings in the simulator."""
import hashlib
import json
import time

from conftest import APP
from test_chat import mark, no_lua_errors, shot, start_app, type_text, wait


# The simulator's clock starts at 2026-01-01 00:00 UTC.
SIM_NOW = 1767225600


SEEN = set()


def settled(sim, name, probe=None):
    """A screenshot of a new screen. The simulator can hand back the frame
    before the change, so retake until the image differs from every earlier
    screenshot of this module (a screen is never drawn twice in these tests)."""
    for _ in range(40):
        path = shot(sim, name)
        digest = hashlib.md5(path.read_bytes()).hexdigest()
        ok = True
        if probe:  # a pixel the target screen lights and the previous one does not
            from PIL import Image
            (x, y), want = probe
            got = Image.open(path).convert("RGB").getpixel((x, y))
            ok = all(abs(a - b) < 24 for a, b in zip(got, want))
        if ok and digest not in SEEN:
            SEEN.add(digest)
            return path
        time.sleep(0.25)
    raise AssertionError(f"{name}: only stale frames")


def note(sim):
    """Remembers the current screen, so a stale frame of it is not taken for the next."""
    SEEN.add(hashlib.md5(sim.screenshot()).hexdigest())


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
    note(sim)
    m = mark(sim)
    sim.keypress("f1")
    wait(sim, r"\[app\] screen lists", m)
    time.sleep(0.5)
    settled(sim, "recent-chats.png", ((200, 60), (40, 70, 130)))
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


def test_settings_keys(llmchat):
    """Gateways spec 5.4: a key per service, all four saved to keys.txt."""
    sim, api, data = llmchat(keys=False)
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    note(sim)
    m = mark(sim)
    sim.keypress("f5")
    wait(sim, r"\[app\] screen settings", m)
    time.sleep(0.5)
    settled(sim, "settings.png", ((4, 34), (40, 70, 130)))
    names = ("anthropic", "opencode", "openrouter", "vercel")  # the first four rows
    for i, name in enumerate(names):
        sim.keypress("enter")
        time.sleep(0.2)
        type_text(sim, f"sk-e2e-{name}-0123456789")
        time.sleep(0.3)
        if i == 0:
            settled(sim, "settings-editing.png")
        sim.keypress("enter")
        time.sleep(0.3)
        sim.keypress("down")
        time.sleep(0.1)
    time.sleep(0.3)
    settled(sim, "settings-masked.png")
    m = mark(sim)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)
    keys = (data / "keys.txt").read_text()
    assert keys.splitlines()[1:] == [f"{n}=sk-e2e-{n}-0123456789" for n in names]
    logged = "\n".join(l["text"] for l in sim.get_log_lines())
    assert "0123456789" not in logged
    assert (data / "prefs.json").exists()
    assert sim.is_alive()
    no_lua_errors(sim)
