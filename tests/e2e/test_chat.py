"""The chat screen in the simulator against a fake API: the real picocalc
under the app's own logic (the host tests cover that in depth)."""
import re
import time
from pathlib import Path

from conftest import APP

SHOTS = Path(__file__).resolve().parents[2] / "build" / "shots"


def mark(sim):
    """The sequence number after the newest log line: wait() from here sees
    only what the next action causes."""
    lines = sim.get_log_lines()
    return (lines[-1]["seq"] + 1) if lines else 0


def wait(sim, pattern, since=0, timeout=20):
    return sim.wait_for_log(pattern, timeout=timeout, since_seq=since, src="lua")


def wait_count(sim, pattern, n, timeout=20):
    """Waits until at least n log lines match: robust against a line from an
    earlier step being taken for the one just caused."""
    end = time.time() + timeout
    while time.time() < end:
        if sum(1 for l in sim.get_log_lines() if re.search(pattern, l["text"])) >= n:
            return
        time.sleep(0.1)
    raise AssertionError(f"{n} x {pattern!r} not seen")


def no_lua_errors(sim):
    errors = [l["text"] for l in sim.get_log_lines() if l.get("src") == "err"]
    assert not errors, errors


def start_app(sim):
    m = mark(sim)
    sim.launch_app(APP)
    return m


def type_text(sim, text):
    for c in text:
        sim.keypress(c)
        time.sleep(0.03)


def shot(sim, name):
    SHOTS.mkdir(parents=True, exist_ok=True)
    path = SHOTS / name
    path.write_bytes(sim.screenshot())
    return path


def test_send_and_stream(llmchat):
    sim, api, data = llmchat()
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)  # the first frame
    shot(sim, "new-chat.png")
    m = mark(sim)
    type_text(sim, "hi")
    sim.keypress("\n")
    wait(sim, r"\[chat\] done \d+ chars", m)
    time.sleep(0.5)  # the frame drawn after the log line
    path = shot(sim, "reply.png")
    assert path.stat().st_size > 1000
    assert sim.is_alive()
    streamed = [r for r in api.requests if r["stream"]]
    assert len(streamed) == 1 and streamed[0]["provider"] == "anthropic"
    assert streamed[0]["headers"].get("x-api-key") == "sk-ant-fake-key"
    no_lua_errors(sim)


def test_midstream_screenshot(llmchat):
    sim, api, data = llmchat()
    api.delay = 0.4
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    type_text(sim, "hi")
    sim.keypress("\n")
    time.sleep(1.5)
    shot(sim, "streaming.png")
    wait(sim, r"\[chat\] done \d+ chars", m, timeout=30)
    no_lua_errors(sim)


def test_markdown_reply_and_scroll(llmchat):
    """A reply with a list and a code panel, then a longer conversation."""
    sim, api, data = llmchat()
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    type_text(sim, "@markdown")
    sim.keypress("\n")
    wait(sim, r"\[chat\] done \d+ chars", m)
    time.sleep(0.5)
    shot(sim, "markdown.png")
    for n in (2, 3):
        type_text(sim, "more")
        sim.keypress("\n")
        wait_count(sim, r"\[chat\] done \d+ chars", n)
        time.sleep(0.3)
    time.sleep(0.5)
    shot(sim, "long.png")
    sim.keypress("up")
    time.sleep(0.3)
    shot(sim, "long-up.png")
    assert sim.is_alive()
    no_lua_errors(sim)


def shift_press(sim, key):
    """A key with Shift held: the simulator holds the shift button (press),
    clicks the key, then releases shift."""
    sim.call("inject_button", {"button": "shift", "action": "press"})
    time.sleep(0.15)
    sim.keypress(key)
    time.sleep(0.2)
    sim.call("inject_button", {"button": "shift", "action": "release"})
    time.sleep(0.2)


def test_shift_enter_makes_a_newline(llmchat):
    sim, api, data = llmchat()
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    type_text(sim, "ab")
    shift_press(sim, "enter")
    type_text(sim, "cd")
    time.sleep(0.5)
    assert not api.requests, "Shift+Enter must not send"
    # two lines in the compose box: text lit on the box's first and second row.
    # A screenshot can catch a frame still being presented, so look again.
    from PIL import Image

    def lit(im, y0, y1):
        return any(sum(im.getpixel((x, y))) > 300 for x in range(8, 40) for y in range(y0, y1))

    ok = False
    for _ in range(10):
        im = Image.open(shot(sim, "shift-enter.png")).convert("RGB")
        if lit(im, 273, 281) and lit(im, 282, 291):
            ok = True
            break
        time.sleep(0.3)
    assert ok, "two lines in the compose box"
    no_lua_errors(sim)


def test_esc_stops_a_streaming_reply(llmchat):
    sim, api, data = llmchat()
    api.delay = 0.5
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    m = mark(sim)
    type_text(sim, "hi")
    sim.keypress("\n")
    time.sleep(3.5)  # some text has arrived; the whole stream takes about 6 s
    sim.keypress("esc")
    line = wait(sim, r"\[chat\] stopped \d+ chars", m)
    assert not line.endswith(" 0 chars"), "the partial reply was kept"
    time.sleep(0.4)
    shot(sim, "stopped.png")
    assert sim.is_alive(), "the first Esc only stops the reply"
    chats = list((data / "chats").glob("*.json"))
    assert any("Reply stopped" in p.read_text() for p in chats if p.name != "index.json")
    no_lua_errors(sim)
