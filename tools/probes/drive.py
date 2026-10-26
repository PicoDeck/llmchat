#!/usr/bin/env python3
"""Drive the stop and json probes on the PicoDeck simulator or the device.

  python3 tools/probes/drive.py sim stop
  python3 tools/probes/drive.py hw stop  <serial-port>
  python3 tools/probes/drive.py hw json <serial-port>
  python3 tools/probes/drive.py sim lists
  python3 tools/probes/drive.py hw lists <serial-port>

Needs the picodeck checkout (PICODECK, default ~/Projects/PicoDeck/picodeck).
The device is driven without log capture in this process (it loses injected
keys); results come from the app's /data/<id>/results.txt.
"""
import os, shutil, sys, tempfile, time
from pathlib import Path

PICODECK = Path(os.environ.get("PICODECK", Path.home() / "Projects/PicoDeck/picodeck"))
sys.path.insert(0, str(PICODECK / "tests/e2e"))
HERE = Path(__file__).resolve().parent
IDS = {"stop": "dev.llmchat.probe.stop", "json": "dev.llmchat.probe.json",
       "lists": "dev.llmchat.probe.lists"}
NAMES = {"stop": "stopprobe", "json": "jsonprobe", "lists": "listsprobe"}


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


def choose_item(t, case, menu_wait, tries=3):
    """Open the system menu and press Enter on its first item (the app's
    "Stop probe"), re-pressing Enter up to `tries` times, `menu_wait` s apart,
    until the case logs `caught` or `other`. Returns the case's result line."""
    t.keypress("menu")
    for _ in range(tries):
        time.sleep(menu_wait)  # from a tight loop the menu takes seconds to open
        t.keypress("enter")
        end = time.monotonic() + 4
        while time.monotonic() < end:
            for l in results(t, "stop"):
                if l.startswith(f"{case} caught") or l.startswith(f"{case} other"):
                    return l
            time.sleep(0.5)
    return None


def drive_stop(t, settle, menu_wait):
    """The app is already launched. `settle`: wait before the first key (keys
    within ~8 s of a launch are dropped on the device)."""
    time.sleep(settle)
    for case in "ABC":
        if not wait_line(t, "stop", f"{case} running", 30):
            print(case, "never started", results(t, "stop")); return
        r = choose_item(t, case, menu_wait)
        print(case, "->", r or "NO RESULT after 3 Enter presses (STOP does not work?)")
        if not r:
            break
    print("RESULTS:", results(t, "stop"))


def cleanup_hw(t, which):
    """Leave the device at the launcher with no probe files; warn on failure."""
    try:
        print("cleanup exit:", t.command("exit", timeout=3.0))
        end = time.monotonic() + 15
        while time.monotonic() < end and t.status()["app"] != "launcher":
            time.sleep(1)
        if t.status()["app"] != "launcher":
            print("WARNING: app still running; use Sym -> Exit App or reboot")
    except Exception as e:
        print("WARNING: could not exit the app:", e)
    for path in (f"/apps/.dev/{NAMES[which]}", f"/data/{IDS[which]}"):
        try:
            print(t.command(f"rm {path}", 10.0)[-1])
        except Exception as e:
            print("WARNING: could not remove", path, e)


def delete_quiet(t, path):
    try:
        t.delete_file(path)
    except Exception:
        pass


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
            src = HERE / which
            if which == "lists" and os.environ.get("PROBE_OWN") != "1":  # with the app's own modules beside it
                src = Path(tempfile.mkdtemp()) / "lists"
                shutil.copytree(HERE / "lists", src)
                (src / "src").mkdir()
                for mod in ("modellists", "services", "http", "picker"):
                    shutil.copy(HERE.parents[1] / "src" / f"{mod}.lua", src / "src")
            t.push_app(src, NAMES[which], hidden=True)
            if which == "stop":
                t.launch_app(NAMES["stop"]); drive_stop(t, 1.0, 1.5)
            elif which == "lists":
                t.launch_app(NAMES[which]); wait_line(t, which, "done", 300)
                print("RESULTS:", results(t, which))
            else:
                t.launch_app(NAMES[which]); time.sleep(3); print(results(t, which))
        finally:
            sim.stop()
            print("health:", sim.health_problems())
    else:
        import asyncio, hw_target
        port = sys.argv[3]
        if which == "lists" and os.environ.get("PROBE_OWN") != "1":  # with the app's own modules beside it
            staged = Path(tempfile.mkdtemp()) / "lists"
            shutil.copytree(HERE / "lists", staged)
            (staged / "src").mkdir()
            for mod in ("modellists", "services", "http", "picker"):
                shutil.copy(HERE.parents[1] / "src" / f"{mod}.lua", staged / "src")
            HERE_PUSH = staged
        else:
            HERE_PUSH = HERE / which
        t = hw_target.HwTarget(port)  # not connect(): no log capture here
        pm = t.pm
        print("status", t.status())
        out = asyncio.run(pm.push_app(str(HERE_PUSH), NAMES[which], device=port, hidden="dev"))
        print(out.splitlines()[0])
        try:
            delete_quiet(t, f"/data/{IDS[which]}/results.txt")
            print("launch", t.command(f"launch .dev/{NAMES[which]}", timeout=10.0))
            if which == "stop":
                drive_stop(t, 9, 5)
            elif which == "lists":
                wait_line(t, which, "done", 300)
                print("RESULTS:", results(t, which))
            else:
                time.sleep(10); print("RESULTS:", results(t, "json"))
        finally:
            cleanup_hw(t, which)



main()
