# Follow-ups

Open items left when LLM Chat 2.0 was merged (2026-10-26). The build was reviewed task by task and then as a whole branch. Everything here was judged safe to merge, but some of it must be done before a release tag.

## Needs the API keys

- The Claude fixtures (`claude-text`, `-thinking`, `-maxtokens`, `-title`, `-401`) are real recordings since 2026-10-26, and so are Vercel's and OpenCode's (`text`, `reasoning`, `length`, `title`, `401`) and OpenRouter's 401. Still hand-written: `claude-error`, `-fallback`, `-refusal` (`.hand.sse`, which can't be recorded on demand), `claude-markdown.sse` (for the e2e screenshots), and `openrouter-text.hand.sse` / `openrouter-error.hand.sse`: the owner's OpenRouter key has expired. Once it is renewed, record `tools/record_stream.py openrouter text|reasoning|length|title`, and run `tools/probes/cc.py openrouter <model> --long` and the effort probe there (gateways verify-first 3 and 4 skipped OpenRouter).
- Write and run the stream and POST-size probes (plan Task 1, Steps 1, 2, 6 and 7; `tools/probes/` has only the key-free ones so far). Then set the long-chat limit `LONG_BYTES` in `src/chat.lua` from the POST probe (it is 150 KB for now).
- Run the PENDING rows in `docs/device-checklist.md`: real chats on each service, the list downloads and the picker (rows 17-22), streaming smoothness, memory after a long chat, the prompt-cache check, ids near midnight, the old-key import, opening a 150 KB chat, the frame rate while a program streams, and the cost of the run-over gate and of the save at send.

## Gateways and the model picker (2026-10-26)

- **Done on the device (2026-10-26):** the lists probe and the app's list downloads, filtering and the switch line (checklist rows 17-22), and real chats on Vercel and OpenCode. They led to the `fix/device-lists` changes: a pattern scan for the lists (the JSON scanner froze the app for seconds), the picker preparing each list once, and the `http.lua` chunk hand-off race.
- **The owner's Anthropic key is rejected** (401 "invalid x-api-key", from the laptop's keys file too): a real Anthropic chat on the device (row 7) waits for a working key.
- The fetcher scans everything that arrived since the last frame; on the device that is ~150 ms frames at worst while a list downloads. If that ever shows, cap the bytes scanned per frame.
- **OpenCode's Mistral** rejects every effort but `high` with an HTTP 400 that has no message. A chat retries once without the effort field, but its title request doesn't, so a Mistral chat keeps its cut first message as its title.
- The owner's OpenCode account answers `kimi-k3` with 403 "Model access is disabled": the picker lists it, and a chat on it shows "OpenCode refused this request." with that message.
- Later (gateways design 13): prompt caching for Claude models reached through a gateway (OpenRouter needs `cache_control` markers, Vercel `caching: "auto"`); OpenCode's Claude, GPT and Gemini models through their own APIs; remembering a model per chat; prices or context sizes in the picker; `<think>` tags in a reply's text, if a model ever sends them.

## Before release

- **Investigate: a program callback the firmware fires from its hook, and that never returns, can't be stopped.** The firmware fires HTTP, TCP and sound callbacks from its service pass, which runs inside the Lua hook (`lua_service_full`, picodeck `src/os/lua_bridge.c`; `lua_bridge_network.c` says so for HTTP), and Lua runs no hook inside a hook. So a program callback that loops there gets no service pass: no watchdog feed, no exit request, no system menu key. Neither Stop program nor Exit App can reach it, and the watchdog probably resets the device. Not yet checked on the device, and nothing in this app fixes it yet (README and spec 9.7 state it as a known limit). Two directions to try:
  - Run each program callback in a fresh coroutine (in `callbackOf`, `src/sandbox.lua`). A new Lua thread has hooks again, so the firmware's cheap hook work (watchdog, exit request, the system menu key) would run inside it. Whether Stop program or Exit App then works there needs checking on the device.
  - A firmware-side change in picodeck.

## Later

- A stronger Stop program:
  - A "sticky stop": once `run.stopping` is set, every gated function and callback wrapper raises `run.STOP` (as the firmware's own exit does). That closes every remaining way to ignore Stop that passes through a gated call (spec 9.7's list), leaving only loops that compute and touch nothing.
  - `env.load` reads a reader function's whole chunk itself, then loads the string, so an error in the reader no longer runs the runner's message handler and closes the gate early.
  - `callbackOf` returns early once `run.stopping` is set, so after one Stop no program callback runs again.
- The firmware's `picocalc.json` writes an empty table as `{}` (picodeck `lua_bridge_json.c`), so an empty array in a raw Claude block would go back as `{}` and Claude would reject the chat for good. No recorded block has one, and `raw_blocks_hold_no_empty_tables` (`tests/test_claude.lua`) guards it. Clean the raw blocks before sending if a later feature adds citations or tool blocks.
- picodeck: Exit App during a slowed write leaves the SD bus at 1 MHz after the app exits. Once exit is requested, the firmware re-raises it before every Lua instruction, so the app's reset never runs, and the exit teardown doesn't restore the SD clock (only boot, a remount and a CPU clock change do). It is slow but safe, and most likely during the save at send. The firmware's store, updater and `download.lua` have the same gap. Fix in picodeck: call `sd_set_slow_mode(false)` in the Lua runner's teardown.
- CI runs the tests under one Lua only. Add a job for `build/lua32`, the 32-bit-number build the device matches. `proxied_types_match_firmware` and the two download-library tests check nothing when `PICODECK_ROOT` is unset, so give CI a picodeck checkout.
- Possible slowness on the device:
  - The Markdown parser rescans quadratically on an unmatched `[`: 20,000 `[a` took 11 s on the host, and the parse reruns while streaming (`src/markdown.lua`).
  - The program error screen folds a whole huge line before cutting it: 4 MB took 0.69 s on the host and would take tens of seconds on the device, where Stop can't help. Cut the line first.
  - The long-chat check encodes every item after each reply, about 150 KB on the device. Keep a running size instead.
- Smaller gaps:
  - `store:setKey` doesn't reject a newline in a key.
  - `prefs()` checks `model` and `recent` (gateways design 9.1) but accepts any type for the other fields of a tampered `prefs.json`.
  - An unreadable (rather than corrupt) index or prefs file is treated as defaults and later overwritten, with no `.bad` copy.
  - The Claude request sends `output_config = {}` when no effort is set.
  - Program name extraction is loose (`-- see foo.lua for x` gives `seefoo.lua`).
  - The program error heading isn't wrapped for long names.
  - `sound.sample(seconds)` blank samples can't be made in the sandbox.
  - Settings doesn't resync the thinking, font and instructions widgets when it reopens. Ages in the lists don't refresh while a list is open.
  - The prompt's API notes list sprite and tilemap functions with `(...)` arguments.
