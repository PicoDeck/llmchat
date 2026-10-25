"""LLM Chat in the PicoDeck simulator, talking to a fake API.

Uses PicoDeck's E2E harness from $PICODECK_ROOT (default
~/Projects/PicoDeck/picodeck); the simulator binary is $PICODECK_SIM_BINARY or
that checkout's build_sim/picodeck_simulator (make simulator there)."""
import json
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
PICODECK = Path(os.environ.get("PICODECK_ROOT", Path.home() / "Projects" / "PicoDeck" / "picodeck"))
sys.path.insert(0, str(PICODECK / "tests" / "e2e"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from picodeck_simulator import PicodeckSimulator  # noqa: E402
from fake_api import FakeAPI  # noqa: E402

APP, APP_ID = "llmchat", "net.picodeck.llmchat"
APP_FILES = ("app.json", "main.lua", "src", "fonts", "prompt")


def stage_app(dest: Path):
    """Copies the app into dest; a path that doesn't exist yet is skipped."""
    dest.mkdir(parents=True, exist_ok=True)
    for name in APP_FILES:
        src = REPO / name
        if not src.exists():
            continue
        if src.is_dir():
            shutil.copytree(src, dest / name, dirs_exist_ok=True)
        else:
            shutil.copy(src, dest / name)


@pytest.fixture
def llmchat(tmp_path):
    """start(provider="claude", keys=True, prefs=None) -> (sim, api, data_dir).

    Stages the app on a fresh SD card and starts a FakeAPI. prefs.json points
    claude_base / openai_base at it (and selects `provider`; `prefs` adds more
    keys); with keys, keys.txt holds fake keys for both providers. Launching
    is the test's job: sim.launch_app(APP)."""
    started = []

    def start(provider="claude", keys=True, prefs=None):
        api = FakeAPI().start()
        sd = tmp_path / f"sd{len(started)}"
        stage_app(sd / "apps" / APP)
        data = sd / "data" / APP_ID
        data.mkdir(parents=True, exist_ok=True)
        (data / "prefs.json").write_text(json.dumps(
            {"provider": provider, "claude_base": api.url, "openai_base": api.url, **(prefs or {})}))
        if keys:
            (data / "keys.txt").write_text("claude=sk-ant-fake-key\nopenai=sk-fake-key\n")
        sim = PicodeckSimulator(binary_path=os.environ.get("PICODECK_SIM_BINARY"),
                                sd_card_path=str(sd), test_mode=True)
        sim.start()
        started.append((sim, api))
        return sim, api, data

    yield start
    for sim, api in started:
        sim.stop()
        api.stop()
