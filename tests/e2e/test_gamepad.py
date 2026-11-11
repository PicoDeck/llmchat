"""A controller and rebound keys in the simulator (picocalc.gamepad,
firmware 0.7.0): every screen is reached and left with the pad alone, and a
letter bound to a pad button still types."""
import json
import re
import time

from fake_api import last_user_text
from test_chat import mark, no_lua_errors, start_app, type_text, wait
from test_lists_settings import SIM_NOW, seed_chats


def tap(sim, button):
    """A controller's button held 100 ms: no key event, only the pad."""
    sim.pad(button, 100)
    time.sleep(0.3)


def screens_since(sim, m):
    return [l["text"] for l in sim.get_log_lines() if l["seq"] >= m and re.search(r"\[app\] screen ", l["text"])]


def test_controller_alone(llmchat):
    sim, api, data = llmchat()
    seed_chats(data, SIM_NOW)
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    # Start Recent chats, B back; A the picker, B back; B Settings, B back.
    for button, screen in (("start", "lists"), ("b", "chat"), ("a", "picker"), ("b", "chat"),
                           ("b", "settings"), ("b", "chat"), ("start", "lists")):
        m = mark(sim)
        tap(sim, button)
        wait(sim, rf"\[app\] screen {screen}$", m)
    tap(sim, "down")
    m = mark(sim)
    tap(sim, "x")  # "Delete this chat?", answered with A
    time.sleep(0.5)
    tap(sim, "a")
    time.sleep(0.5)
    rows = json.loads((data / "chats" / "index.json").read_text())
    assert [r["id"] for r in rows] == ["c1"]
    assert screens_since(sim, m) == [], "the A that answered went on to the list"
    no_lua_errors(sim)


def test_bound_letters_type(llmchat):
    """The browser demo's binding (A is Z, B is X) and Start on S: in the
    compose box and the picker's filter they type; F4 still opens the picker."""
    sim, api, data = llmchat(rebind={"a": ["Z", "F4"], "b": ["X", "F5"], "start": ["F1", "S"]})
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    type_text(sim, "zaxs")
    sim.keypress("\n")
    wait(sim, r"\[chat\] done \d+ chars", m)
    assert screens_since(sim, m) == []
    assert last_user_text([r for r in api.requests if r["stream"]][-1]["body"]) == "zaxs"
    m = mark(sim)
    sim.keypress("f4")
    wait(sim, r"\[app\] screen picker", m)
    time.sleep(0.3)
    m = mark(sim)
    type_text(sim, "s")
    time.sleep(0.5)
    assert screens_since(sim, m) == [], "s filtered"
    sim.keypress("esc")  # clears the filter
    time.sleep(0.3)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)
    no_lua_errors(sim)
