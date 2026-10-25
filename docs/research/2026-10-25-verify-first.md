# Verify-first probes (spec section 12) - partial: key-free probes only

Run 2026-10-25 under controller ruling R20. Probes live in `tools/probes/` (`stop/`, `json/`, `drive.py`). Ids are `dev.llmchat.probe.<name>`.

## 1. Stop probe (spec 9.5, 12.1)

The app registers the menu item `Stop probe` (callback: `error(STOP)`, `STOP` a local table) and runs three cases under `xpcall`. The driver opens the system menu (`menu` key) and presses Enter on the first item, once per case.

| Case | Loop | Simulator | Device |
|---|---|---|---|
| A | `while true do end` | `A caught` | `A caught` |
| B | `while true do sys.sleep(100) end` | `B caught` | `B caught` |
| C | `input.update()`, `display.clear()`, `display.flush()` | `C caught` | `C caught` |

`STOP_WORKS (A, sim) = yes`, `(B, sim) = yes`, `(C, sim) = yes`.
`STOP_WORKS (A, device) = yes`, `(B, device) = yes`, `(C, device) = yes`.

After `C caught` the app logged `done` and returned to the launcher. Simulator health check: no problems. No case ended with `other:`.

Procedure (exactly what `tools/probes/drive.py` does): launch, wait for `<case> running` in `/data/dev.llmchat.probe.stop/results.txt`, send the `menu` key, then up to 3 times: wait, press Enter (first menu item is the app's "Stop probe"), poll up to 4 s for `<case> caught` or `<case> other`. The first key waits for 9 s after launch on the device (1 s on the simulator; keys within ~8 s of a launch are dropped on the device). The wait before each Enter is 5 s on the device and 1.5 s on the simulator. If a case gets no result after 3 presses the driver stops. On the device a `finally` then sends `exit`, and removes `/apps/.dev/<probe>` and `/data/dev.llmchat.probe.*`, warning if a step fails. The first device run used a single Enter 1.5 s after `menu` (lost), then a manual Enter; the final script run (5 s wait, retries) got all three on the first press.

What this shows: the error raised by the menu callback reaches the probe's own `xpcall` around the looping function, in all three loops. That is the shape Task 15's runner will use (an `xpcall` around the program). It does not show anything about code that has its own `pcall`.

## Note for Task 15
- A program that wraps its work in its own `pcall` can swallow the STOP error (spec 9.7). Not tested here; the system menu's Exit App remains the last resort.
- On the device the menu takes several seconds to open from a tight loop: wait about 5 s after the menu key before choosing the item.

No BLOCKER for Task 15.

## 2. JSON probe (spec 12.4)

Input: the `content_block_delta` data line from `tests/fixtures/claude-text.sse` (172 bytes; provisional hand-written fixture with the real wire shape). `picocalc.json.decode`, 500 decodes, on the device (Lua timer `getTimeUs`):

- run 1: total 203923 us, avg **407 us**
- run 2: total 194755 us, avg **389 us**

Average about 400 us, under the 2000 us threshold, so Task 10 decodes every event with `picocalc.json.decode`; no pattern fast path. (A real Claude delta line may be a little longer or shorter; the cost is dominated by per-call overhead at this size.)

## 3. Decisions

- `STOP_WORKS = yes` for A, B and C, on the simulator and the device.
- `LONG_BYTES = 150 KB (provisional; POST probe pending)`
- JSON: no fast path.

## Pending: needs a Claude key

Not run, by ruling R20 (no API keys yet):
- Step 1 (keys file) and Step 2 (`docs/research/api-spend.md`).
- Step 6, stream probe (spec 12.2): SSE chunk delivery latency on the device.
- Step 7, POST probe (spec 12.3): largest POST body (64/256/512 KB) the device sends; `LONG_BYTES = min(150 KB, 60% of the largest success)` is to be set from it.
- Re-run the JSON probe against a recorded real delta line if the fixture is replaced by `tools/record_stream.py`.

## Device state

Probe apps removed from `/apps/.dev` and their `/data/dev.llmchat.probe.*` directories deleted; the device is idle at the launcher.
