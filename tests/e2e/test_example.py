"""The example program from the system prompt runs in the simulator (spec 10)."""
import time

from conftest import REPO
from test_chat import mark, shot, wait, no_lua_errors
from test_programs import launch, send, saved_text, still_running


def test_example_runs_and_returns(llmchat):
    sim, api, data = launch(llmchat)
    send(sim, "@prog-example")
    m = mark(sim)
    sim.keypress("f3")
    time.sleep(1.0)
    sim.keypress(" ")
    time.sleep(0.5)
    shot(sim, "program-example.png")
    sim.keypress("esc")
    wait(sim, r"\[run\] example\.lua ended \d+ s", m)
    wait(sim, r"\[app\] screen chat", m)
    assert "example.lua ended after" in saved_text(data)
    still_running(sim)
    no_lua_errors(sim)
