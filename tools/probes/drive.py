#!/usr/bin/env python3
"""Drive the stop and json probes on the PicoDeck simulator or the device.

  python3 tools/probes/drive.py sim stop
  python3 tools/probes/drive.py hw stop  <serial-port>
  python3 tools/probes/drive.py hw json <serial-port>

Needs the picodeck checkout (PICODECK, default ~/Projects/PicoDeck/picodeck).
The device is driven without log capture in this process (it loses injected
keys); results come from the app's /data/<id>/results.txt.
"""
import os, shutil, sys, tempfile, time
from pathlib import Path

PICODECK = Path(os.environ.get("PICODECK", Path.home() / "Projects/PicoDeck/picodeck"))
sys.path.insert(0, str(PICODECK / "tests/e2e"))
HERE = Path(__file__).resolve().parent
IDS = {"stop": "dev.llmchat.probe.stop", "json": "dev.llmchat.probe.json"}
NAMES = {"stop": "stopprobe", "json": "jsonprobe"}


def results(t, which):
    try:
        return t.read_file(f"/data/{IDS[which]}/results.txt").decode().splitlines()
    except FileNotFoundError:
        return []


def wait_line(t, which, text, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if any(l == text for l in results(t, which)):
            return True
        time.sleep(0.5)
    return False


def drive_stop(t, settle):
    t.delete_file(f"/data/{IDS['stop']}/results.txt")
    print("launch", t.launch_app(NAMES["stop"]))
    for case in "ABC":
        if not wait_line(t, "stop", f"{case} running", 30):
            print(case, "never started", results(t, "stop")); return
        time.sleep(settle)  # keys within ~8 s of launch are dropped on the device
        t.keypress("menu")
        time.sleep(1.5)
        t.keypress("enter")  # first menu item is the app's "Stop probe"
        nxt = {"A": "B running", "B": "C running", "C": "done"}[case]
        ok = wait_line(t, "stop", nxt, 20)
        print(case, "->", "advanced" if ok else "NO PROGRESS (still looping?)")
        if not ok:
            break
    print("RESULTS:", results(t, "stop"))


def main():
    mode, which = sys.argv[1], sys.argv[2]
    if mode == "sim":
        from helpers import build_sd_card
        from picodeck_simulator import PicodeckSimulator
        import hw_target
        tmp = Path(tempfile.mkdtemp())
        sd = build_sd_card(tmp / "sd", fixtures=[], reserve=1)
        sim = PicodeckSimulator(binary_path=str(PICODECK / "build_sim/picodeck_simulator"),
                                sd_card_path=str(sd), headless=True, test_mode=True)
        sim.start()
        try:
            t = hw_target.SimTarget(sim)
            t.push_app(HERE / which, NAMES[which], hidden=True)
            if which == "stop":
                drive_stop(t, 1.0)
            else:
                t.launch_app(NAMES[which]); time.sleep(3); print(results(t, which))
        finally:
            sim.stop()
            print("health:", sim.health_problems())
    else:
        import asyncio, hw_target
        port = sys.argv[3]
        t = hw_target.HwTarget(port)  # not connect(): no log capture here
        pm = t.pm
        print("status", t.status())
        out = asyncio.run(pm.push_app(str(HERE / which), NAMES[which], device=port, hidden="dev"))
        print(out.splitlines()[0])
        t.delete_file(f"/data/{IDS[which]}/results.txt")
        lines = t.command(f"launch .dev/{NAMES[which]}", timeout=10.0)
        print("launch", lines)
        if which == "stop":
            time.sleep(9)
            drive_stop_hw(t)
        else:
            time.sleep(10); print("RESULTS:", results(t, "json"))


def drive_stop_hw(t):
    # app already launched; reuse the case loop without relaunching
    for case in "ABC":
        if not wait_line(t, "stop", f"{case} running", 30):
            print(case, "never started", results(t, "stop")); return
        t.keypress("menu"); time.sleep(5); t.keypress("enter")  # menu takes seconds to open from a tight loop
        nxt = {"A": "B running", "B": "C running", "C": "done"}[case]
        ok = wait_line(t, "stop", nxt, 20)
        print(case, "->", "advanced" if ok else "NO PROGRESS")
        if not ok:
            break
    print("RESULTS:", results(t, "stop"))


main()
