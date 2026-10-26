# Device checklist

The checks from spec section 11 ("Device checks") and the gateways design's section 10, to run on a real PicoCalc before a release tag. Last run: 2026-10-25, on the owner's PicoCalc (USB), under controller ruling R25: only the checks that need no API key were run. The rest are PENDING. Rows 17-22 came with the gateways and the model picker (2026-10-26); OpenAI's row went with OpenAI.

Result: PASS, FAIL or PENDING.

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | App installs and launches to the new-chat screen | PASS | Pushed to `/apps/.dev/llmchat` with `push_app(hidden="dev")`, started with `launch .dev/llmchat`. Opens on "Ask anything", cursor in the compose box. |
| 2 | Keys from `keys.txt` over USB are read | PASS | Dummy `claude=dummy-key-not-real` written to `/data/net.picodeck.llmchat/keys.txt`; Settings shows **Claude key** as `***************real` (masked) and OpenAI key as "not set". No real key was used. |
| 3 | A saved program runs from the Programs tab; Esc returns | PASS | `example.lua` (a counter) placed as the app saves programs (`programs/<name>.lua` plus `programs/index.json`, no owner chat). Enter ran it, Space counted, Esc returned to Programs with "example.lua ended after 15 s". |
| 4 | "Stop program" ends `while true do end` | PASS | `spin.lua` run from the Programs tab; system menu opened, waited 5 s, Enter on "Stop program": back on Programs with "spin.lua stopped after 9 s" (18 s on the first run). Menu first item is "Stop program". Done twice. |
| 5 | Lowest free heap after a program run | PASS (measured) | See "Memory" below. |
| 6 | Memory at the new-chat screen (sandbox module loaded) | PASS (measured) | See "Memory" below. |
| 7 | A real Anthropic chat over TLS (`anthropic/claude-opus-5-5`, or Haiku to spend less) | BLOCKED (key) | 2026-10-26: the laptop's Anthropic key is now rejected (401 "invalid x-api-key", checked from the laptop too). On the device the app showed the right note, "Anthropic rejected the API key. Check Settings." with the message under it, and Enter retry. Run again with a working key. |
| 8 | A real gateway chat over TLS on each keyed service: `vercel/deepseek/deepseek-v4.1-flash-1017`, `opencode/deepseek-v4.1-flash`, and `openrouter/...` once the OpenRouter key is renewed (it has expired) | PASS (Vercel, OpenCode) | 2026-10-26: `vercel/deepseek/deepseek-v4.1-flash-1017` and `opencode/deepseek-v4.1-flash` answered over TLS with the firmware's User-Agent; the replies streamed with the grey and yellow bars, the title ("Scattering and Chlorophyll") came from the chat's own model, and the chat file holds `provider` = service and `model` = full id. OpenRouter waits for a renewed key. |
| 9 | Streaming looks smooth | PENDING | needs the owner's API keys |
| 10 | Lowest free heap after a long real chat plus a program run | PENDING | needs the owner's API keys (item 5 covers a program run without a long chat) |
| 11 | Prompt cache: `usage.cache_read_input_tokens > 0` on a second request, for each default model (ruling R7) | PENDING | needs the owner's API keys |
| 12 | Chat ids near midnight (`getClock` fields) | PENDING | needs the owner's API keys (needs a real chat near midnight, or the device clock set) |
| 13 | The old app's key import (`Store:importOld`) on a device | PENDING | It has never run on hardware: the device copy for items 1-6 had the import removed. It copies the old app's `llmchat_api_key` to `keys.txt`, then **clears it from the old app's config**, so run it on a card whose old config can be lost (or back up `/data/<old id>/config.json` first). Check: the key lands in `keys.txt` under the right provider, Settings shows it masked, and the old keys are gone. |
| 14 | Opening a ~150 KB chat (the `LONG_BYTES` note size) | PENDING | Host: 112 ms. On the device: time from Enter in Recent chats to the chat drawn, and the free heap after. Also the save a send makes (final review I1). Since 2026-10-26 it runs before the request goes out, at full speed (0.1-0.2 s for a 150 KB chat by the review's estimate), so it adds that before the first words; it used to run once the request was on its way, in slow mode (SPI0 at 1 MHz, about 1.3-1.5 s), and a gateway's stream arriving meanwhile filled the firmware's buffer ("Connection lost"). Time it. Needs a long chat, so a real API key (or a staged chat file). |
| 15 | Frame rate while a long program block streams | PENDING | needs the owner's API keys. A reply with a 100+ line Lua block: the live layout re-lays only the tail after the last blank line outside a fence (spec 7.4), but a block has no blank line outside a fence, so the open block is laid out again on each bump. Watch for lag on the device. |
| 16 | Program speed and memory with the run-over gate (final review C1) | PENDING | Every picocalc call a program makes now goes through a gated wrapper (one Lua call and a pcall). Host: about 140 ns a call against 30 ns direct; one run's env grew from 23 KB to 36 KB (64-bit host). On the device: `example.lua` and `dice.lua` stay smooth, a loop of 10,000 `display.fillRect` calls is timed, and items 5 and 6 are measured again. No key needed. |
| 17 | The verify-first lists probe (`python3 tools/probes/drive.py hw lists <port>`) | PASS (after fixes) | 2026-10-26, details in `docs/research/2026-10-26-gateways-verify-first.md` ("On the device"). The first run failed (the app's scanner ran at ~35 KB/s, frames of seconds) and found the `http.lua` chunk hand-off race; after the fixes on `fix/device-lists`: Vercel 5.2 s at 28 fps, OpenRouter 11.7 s at 42 fps, longest frames ~150 ms, both complete, both at once 15.6 s at 32 fps, lowest free 5.19 MB. |
| 18 | The app's own list downloads: open the picker (F4) with the Vercel, OpenCode and OpenRouter keys and no saved lists | PASS | 2026-10-26 (the app, Vercel and OpenCode keyed): `[models] vercel saved 269 ids in 5617 ms`; OpenCode's list came back with 8 ids (with the key it lists what the account can use: the anonymous list keeps 17). The picker stayed responsive meanwhile. Not checked here: Esc mid-download (e2e and host tests cover it). |
| 19 | Filtering about 700 ids: type `flash`, then `ds flash`, then Backspace | PASS | 2026-10-26: typing into the filter over 282 ids kept up with the keys; the probe's figures over 662 ids: 72 ms for the first letter, 40 ms for `flash` (later keystrokes narrow the last result). |
| 20 | The switch line: a reply on one model, F4 to another, send | PASS | 2026-10-26: a Vercel reply, F4 to `opencode/deepseek-v4.1-flash`, send: "now opencode/deepseek-v4.1-flash" drawn dim between two rules (as mockup 13), the reply with OpenCode's bar, the note stored as `kind = "model"`. |
| 21 | A list download while a reply streams (TWO_CONNECTIONS) | PASS (probe) | 2026-10-26: two list downloads at once on the device were complete at 32 fps (row 17). The app still holds a list back while a reply arrives; not watched on the device. |
| 22 | Settings: the four key rows mask and save; `keys.txt` written with the four names | PASS | 2026-10-26: Settings showed the Anthropic key as `sk-ant-***...` and the gateway keys as stars and their last 4 characters, OpenRouter "not set". The test copy's `prefs.json` held `model` and `recent` and no `provider`/`models`. |

## Memory (items 5 and 6)
Measured with `picocalc.sys.getMemInfo()` inside the app. The device build was a staged copy of the repo's app whose `main.lua` wrapped `App:runProgram` and the frame loop to write `getMemInfo()` snapshots to a file (`collectgarbage("collect")` first after a run), read back over USB. The staged copy also had the old-key import line (`importOld`) removed so the test could not touch the owner's old app config. Nothing from the wrapper is in the repo.

| Moment | PSRAM free | PSRAM used | Largest free block | Lua heap |
|---|---|---|---|---|
| New-chat screen, 4 s after start | 5,489,200 B (5.24 MB) | 671,184 B (655 KB) | 5,472,600 B | 359 KB |
| Just before running `example.lua` (Programs tab open) | 5,438,600 B | 721,784 B | 5,423,000 B | 401 KB |
| After `example.lua` ended, back in the app | 5,485,200 B | 675,184 B | 5,411,400 B | 348 KB |
| After `spin.lua` stopped | 5,485,000 B | 675,384 B | 5,407,200 B | 348 KB |

- Lowest free heap sampled (every 500 ms while the app's own loop ran, not inside a program): **5,438,600 B**, just before a run. Free heap does not fall after runs: no leak across two runs, one stopped. The largest free block slips a little (5.47 MB to 5.41 MB, fragmentation 1% to 2%).
- Not measured: the peak inside a running program (the app's loop is not running then). The system menu showed "PSRAM 1345k/6016k used" while `spin.lua` ran, but the menu itself holds a 400 KB backdrop and a 400 KB screen copy, so that is not the program's usage.
- The launcher logs `PSRAM free=5875K largest=5735K frag=3%` after the app exits (the same as after other apps), and the app's stack high-water mark was 5,904 of 65,536 bytes.

## Gateways run, 2026-10-26
The test copy ran as its own app (`app.json` id `dev.llmchat.gateways`, staged at `/apps/.dev/llmchatdev`), so it had its own data folder: the owner had set up the installed LLM Chat 2.0.0 since the last run, and `/data/net.picodeck.llmchat/` holds the owner's `keys.txt`, prefs and a chat, which were not read or changed. Only the Anthropic, Vercel and OpenCode keys went into the test folder; the folder and the test copy were removed afterwards, and the owner's folder listed the same files and sizes after as before. Keys injected over the dev console within ~8 s of the launch, and an Enter sent straight after a burst of typed characters, were dropped; a pause before Enter fixed it (the harness, not the app: the second Enter always worked).

## Not run, and why
Everything marked PENDING needs a real API key. The owner has not supplied keys, and no API spend was made (no `docs/research/api-spend.md` entries). `docs/research/2026-10-25-verify-first.md` lists the other key-dependent probes (stream latency, POST size / `LONG_BYTES`).

## Device state left
`/apps/llmchat` (the owner's installed old LLM Chat) was never touched. The test copy `/apps/.dev/llmchat` was removed. `/data/net.picodeck.llmchat/` held only `config.json` (304 bytes) before and after; the test files (`keys.txt`, `programs/`, `prefs.json`, `mem.txt`) were removed. The device is at the launcher.
