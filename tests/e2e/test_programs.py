"""Running programs in the simulator (spec 9.2-9.6): each program is a fixture
in tests/fixtures/programs/, delivered as a fake reply ("@prog-<name>"), saved
by the app and run with F3."""
import json
import shutil
import time

from conftest import REPO
from fake_api import last_user_text
from test_chat import mark, no_lua_errors, shot, start_app, type_text, wait, wait_count


def send(sim, text):
    """Sends `text` and waits for the reply to finish."""
    m = mark(sim)
    type_text(sim, text)
    sim.keypress("\n")
    wait(sim, r"\[chat\] done \d+ chars", m)
    time.sleep(0.3)


def launch(llmchat, **kw):
    sim, api, data = llmchat(**kw)
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    return sim, api, data


def chat_files(data):
    return [p for p in (data / "chats").glob("*.json") if p.name != "index.json"]


def saved_text(data):
    return "\n".join(p.read_text() for p in chat_files(data))


def still_running(sim):
    """The app answers a key: F1 opens Recent chats, Esc comes back."""
    m = mark(sim)
    sim.keypress("f1")
    wait(sim, r"\[app\] screen lists", m)
    m = mark(sim)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)


# The error screen's panel body, at a point no text covers.
PANEL = ((150, 150), (16, 28, 49))


def stable_shot(sim, name, probe=None):
    """A screenshot taken twice the same (the simulator can hand back a frame
    being drawn) and, with probe = ((x, y), rgb), showing that colour there;
    as a PIL image."""
    from PIL import Image
    last = None
    for _ in range(20):
        path = shot(sim, name)
        data = path.read_bytes()
        im = Image.open(path).convert("RGB")
        ok = probe is None or all(abs(a - b) < 16 for a, b in zip(im.getpixel(probe[0]), probe[1]))
        if ok and data == last:
            return im
        last = data
        time.sleep(0.25)
    raise AssertionError(f"{name}: the screen never settled")


def test_run_and_return(llmchat):
    sim, api, data = launch(llmchat)
    send(sim, "@prog-dice")
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"dice ready", m)
    time.sleep(0.5)
    shot(sim, "program-dice.png")
    sim.keypress("esc")
    wait(sim, r"\[run\] dice\.lua ended \d+ s", m)
    wait(sim, r"\[app\] screen chat", m)
    time.sleep(0.5)
    shot(sim, "program-ended.png")
    assert "dice.lua ended after" in saved_text(data)
    still_running(sim)
    no_lua_errors(sim)


def test_error_screen_and_fix(llmchat):
    sim, api, data = launch(llmchat)
    send(sim, "@prog-boom")
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"\[run\] boom\.lua error \d+ s: boom\.lua:6:", m)
    wait(sim, r"\[app\] screen programError", m)
    time.sleep(0.5)
    stable_shot(sim, "program-error.png", PANEL)
    m = mark(sim)
    sim.keypress("f3")  # runs it again: the error screen comes back
    wait(sim, r"\[run\] boom\.lua error", m)
    wait(sim, r"\[app\] screen programError", m)
    time.sleep(0.3)
    before = len([r for r in api.requests if r["stream"]])
    m = mark(sim)
    sim.keypress("enter")  # "Ask Claude to fix" has the focus
    wait(sim, r"\[app\] screen chat", m)
    wait(sim, r"\[chat\] done \d+ chars", m)
    streamed = [r for r in api.requests if r["stream"]]
    assert len(streamed) == before + 1
    assert last_user_text(streamed[-1]["body"]) == (
        "boom.lua stopped with an error:\n"
        "boom.lua:6: attempt to concatenate a nil value (local 'b')\n"
        "It printed:\n"
        "starting up\n"
        "adding things\n"
        "Please send a fixed version of the whole program.")
    time.sleep(0.5)
    shot(sim, "program-fix-sent.png")
    no_lua_errors(sim)


def test_c_error_keeps_the_program_line(llmchat):
    """A firmware function's error, raised through the run-over gate, still
    names the program's line and the function (spec 9.2 step 5)."""
    sim, api, data = launch(llmchat)
    send(sim, "@prog-badarg")
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"\[run\] badarg\.lua error \d+ s: badarg\.lua:4: bad argument #3 to 'drawText' "
              r"\(string expected, got nil\)", m)
    wait(sim, r"\[app\] screen programError", m)
    no_lua_errors(sim)


def test_sys_exit_keeps_app(llmchat):
    """With OpenAI, so the program also arrives in a Responses stream."""
    sim, api, data = launch(llmchat, provider="openai")
    send(sim, "@prog-exit")
    assert [r["provider"] for r in api.requests if r["stream"]] == ["openai"]
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"exit\.lua says bye", m)
    wait(sim, r"\[run\] exit\.lua exit \d+ s", m)
    wait(sim, r"\[app\] screen chat", m)
    assert not any("never printed" in l["text"] for l in sim.get_log_lines())
    assert "exit.lua ended after" in saved_text(data)
    still_running(sim)
    assert sim.is_alive()
    no_lua_errors(sim)


def test_stop_program_menu(llmchat):
    sim, api, data = launch(llmchat)
    send(sim, "@prog-spin")
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"spinning", m)
    time.sleep(0.5)
    sim.keypress("menu")
    stopped = False
    for _ in range(3):
        time.sleep(1.5)  # from a tight loop the menu takes a moment to open
        sim.keypress("enter")  # the first item is the app's "Stop program"
        try:
            wait(sim, r"\[run\] spin\.lua stopped \d+ s", m, timeout=4)
            stopped = True
            break
        except Exception:
            continue
    assert stopped, "Stop program did not end the loop"
    wait(sim, r"\[app\] screen chat", m)
    assert "spin.lua stopped after" in saved_text(data)
    time.sleep(0.5)
    shot(sim, "program-stopped.png")
    still_running(sim)
    no_lua_errors(sim)


def test_out_of_memory(llmchat):
    """Review Focus 5: a program that allocates until memory runs out shows the
    error screen, and the chat draws and sends normally afterwards."""
    sim, api, data = launch(llmchat)
    send(sim, "@prog-hog")
    m = mark(sim)
    sim.keypress("f3")
    wait(sim, r"\[run\] hog\.lua error \d+ s: not enough memory", m, timeout=60)
    wait(sim, r"\[app\] screen programError", m)
    time.sleep(0.5)
    stable_shot(sim, "program-oom.png", PANEL)
    m = mark(sim)
    sim.keypress("esc")
    wait(sim, r"\[app\] screen chat", m)
    send(sim, "hi")
    time.sleep(0.5)
    shot(sim, "program-oom-after.png")
    assert sum(1 for r in api.requests if r["stream"]) == 2
    assert sim.is_alive()


def test_cleanup_ten_runs(llmchat):
    """fonts.lua loads 6 fonts (the 8 slots less the chat's 2) and opens 3
    files, and leaves them: without cleanup the second run fails to load a
    font, and the chat's saves fail once FatFS's 16 file slots are gone."""
    sim, api, data = llmchat()
    folder = data / "programs" / "fonts.data"
    folder.mkdir(parents=True, exist_ok=True)
    for i in range(1, 7):
        shutil.copy(REPO / "fonts" / "sans.pfn", folder / f"f{i}.pfn")
    wait(sim, r"\[app\] screen chat", start_app(sim))
    time.sleep(0.5)
    send(sim, "hi")
    time.sleep(0.5)
    before = stable_shot(sim, "fonts-before.png").crop((0, 30, 320, 268))
    m = mark(sim)
    sim.keypress("f2")
    time.sleep(0.5)
    send(sim, "@prog-fonts")
    for n in range(1, 11):
        sim.keypress("f3")
        wait_count(sim, r"\[run\] fonts\.lua ended \d+ s", n)
        time.sleep(0.3)
    assert not any(" error " in l["text"] for l in sim.get_log_lines() if l["text"].startswith("[run]"))
    shot(sim, "fonts-runs.png")
    sim.keypress("f2")
    time.sleep(0.5)
    send(sim, "hi")
    time.sleep(0.5)
    after = stable_shot(sim, "fonts-after.png").crop((0, 30, 320, 268))
    # the same conversation draws the same pixels: the chat still draws in Sans
    assert before.tobytes() == after.tobytes(), "the chat draws differently after the runs"
    assert after.getbbox() is not None, "the conversation is drawn"
    # and still saves: three chats, the second with its ten notes
    index = json.loads((data / "chats" / "index.json").read_text())
    assert len(index) == 3
    assert saved_text(data).count("fonts.lua ended after") == 10
    no_lua_errors(sim)
