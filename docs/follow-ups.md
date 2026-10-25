# Follow-ups

Open items left when LLM Chat 2.0 was merged (2026-10-26). The build was reviewed task by task and then as a whole branch. Everything here was judged safe to merge, but some of it must be done before a release tag.

## Before the first real recording (needs the API keys)

- `tools/record_stream.py`:
  - Refuse a keys file that isn't mode 600.
  - Scrub `rs_`, `fc_` and `item_` ids as well as the ones it already scrubs. Real reasoning recordings carry live `rs_` ids.
  - `log_spend` writes a junk row for error bodies and no header for a new file. Create the spend log when recording starts.
- Replace the hand-written fixtures in `tests/fixtures/` (each starts with a `: provisional` comment) with recordings, and re-run `make test`.
- Check that Claude's raw content blocks survive the JSON round trip. An empty array such as `citations: []` may re-encode as `{}`. History is append-only, so a 400 from this would break that chat on every later request. Either confirm it with the first recordings or clean the raw blocks before sending.
- Write and run the stream and POST-size probes (plan Task 1, Steps 1, 2, 6 and 7; `tools/probes/` has only the key-free ones so far). Then set the long-chat limit `LONG_BYTES` in `src/chat.lua` from the POST probe (it is 150 KB for now).
- Run the PENDING rows in `docs/device-checklist.md`: real Claude and OpenAI chats, streaming smoothness, memory after a long chat, the prompt-cache check, ids near midnight, the old-key import, opening a 150 KB chat, the frame rate while a program streams, and the cost of the run-over gate and of the save at send.

## Before release (one small fix round)

- **The download library is broken inside programs.** picodeck's `system/lib/download.lua` calls `fs.setSlowMode`, which the program allowlist denies (`src/sandbox_api.lua`). So `sys.loadlib("download")` fails with "attempt to call a nil value" inside its own request callback. Give the program environment a no-op or allowed `fs.setSlowMode`, and add a test that runs a fake transfer.
- **A `<close>` handler gets past Stop program.** The error and Stop paths close the run-over gate before the stack unwinds, and Stop requires the gate to be open. So a program's `__close` handler that loops forever can't be stopped; only Exit App ends it. It can't reach the firmware, network, files or menu. Fix: let Stop raise until `_xpcall` returns (`src/sandbox.lua`, near the `_xpcall` call and the Stop menu item). Then correct three claims that overstate this: `README.md` ("none of its code runs again", and `pcall` named as the only way to ignore Stop) and the gate comment in `src/sandbox.lua`.
- **The frame guard builds its report outside its pcall** (`src/app.lua`, `App:frame`). An out-of-memory error raised while it reports another error still ends the app. Put one pcall around the whole report.

## Later

- CI runs the tests under one Lua only. Add a job for `build/lua32`, the 32-bit-number build the device matches. `proxied_types_match_firmware` checks nothing when `PICODECK_ROOT` is unset, so give CI a picodeck checkout.
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
