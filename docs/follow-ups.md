# Follow-ups

Open items left when LLM Chat 2.0 was merged (2026-10-26). The build was reviewed task by task and then as a whole branch. Everything here was judged safe to merge, but some of it must be done before a release tag.

## Before the first real recording (needs the API keys)

- Replace the hand-written fixtures in `tests/fixtures/` (each starts with a `: provisional` comment) with recordings, and re-run `make test`.
- Check that Claude's raw content blocks survive the JSON round trip. An empty array such as `citations: []` may re-encode as `{}`. History is append-only, so a 400 from this would break that chat on every later request. Either confirm it with the first recordings or clean the raw blocks before sending.
- Write and run the stream and POST-size probes (plan Task 1, Steps 1, 2, 6 and 7; `tools/probes/` has only the key-free ones so far). Then set the long-chat limit `LONG_BYTES` in `src/chat.lua` from the POST probe (it is 150 KB for now).
- Run the PENDING rows in `docs/device-checklist.md`: real Claude and OpenAI chats, streaming smoothness, memory after a long chat, the prompt-cache check, ids near midnight, the old-key import, opening a 150 KB chat, the frame rate while a program streams, and the cost of the run-over gate and of the save at send.

## Before release

- **Investigate: a program callback the firmware fires from its hook, and that never returns, can't be stopped.** The firmware fires HTTP, TCP and sound callbacks from its service pass, which runs inside the Lua hook (`lua_service_full`, picodeck `src/os/lua_bridge.c`; `lua_bridge_network.c` says so for HTTP), and Lua runs no hook inside a hook. So a program callback that loops there gets no service pass: no watchdog feed, no exit request, no system menu key. Neither Stop program nor Exit App can reach it, and the watchdog probably resets the device. Not yet checked on the device, and nothing in this app fixes it yet (README and spec 9.7 state it as a known limit). Two directions to try:
  - Run each program callback in a fresh coroutine (in `callbackOf`, `src/sandbox.lua`). A new Lua thread has hooks again, so the firmware's cheap hook work (watchdog, exit request, the system menu key) would run inside it. Whether Stop program or Exit App then works there needs checking on the device.
  - A firmware-side change in picodeck.

## Later

- A stronger Stop program:
  - A "sticky stop": once `run.stopping` is set, every gated function and callback wrapper raises `run.STOP` (as the firmware's own exit does). That closes every remaining way to ignore Stop that passes through a gated call (spec 9.7's list), leaving only loops that compute and touch nothing.
  - `env.load` reads a reader function's whole chunk itself, then loads the string, so an error in the reader no longer runs the runner's message handler and closes the gate early.
  - `callbackOf` returns early once `run.stopping` is set, so after one Stop no program callback runs again.
- `tools/record_stream.py` doesn't scrub `call_` ids (OpenAI function-call ids).
- CI runs the tests under one Lua only. Add a job for `build/lua32`, the 32-bit-number build the device matches. `proxied_types_match_firmware` and the two download-library tests check nothing when `PICODECK_ROOT` is unset, so give CI a picodeck checkout.
- Possible slowness on the device:
  - The Markdown parser rescans quadratically on an unmatched `[`: 20,000 `[a` took 11 s on the host, and the parse reruns while streaming (`src/markdown.lua`).
  - The program error screen folds a whole huge line before cutting it: 4 MB took 0.69 s on the host and would take tens of seconds on the device, where Stop can't help. Cut the line first.
  - The long-chat check encodes every item after each reply, about 150 KB on the device. Keep a running size instead.
- Smaller gaps:
  - `store:setKey` doesn't reject a newline in a key.
  - `prefs()` accepts any type from a tampered `prefs.json`.
  - An unreadable (rather than corrupt) index or prefs file is treated as defaults and later overwritten, with no `.bad` copy.
  - The Claude request sends `output_config = {}` when no effort is set.
  - Program name extraction is loose (`-- see foo.lua for x` gives `seefoo.lua`).
  - The program error heading isn't wrapped for long names.
  - `sound.sample(seconds)` blank samples can't be made in the sandbox.
  - Settings doesn't resync the thinking, font and instructions widgets when it reopens. Ages in the lists don't refresh while a list is open.
  - The prompt's API notes list sprite and tilemap functions with `(...)` arguments.
