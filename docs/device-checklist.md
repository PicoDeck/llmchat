# Device checklist

The checks from spec section 11 ("Device checks"), to run on a real PicoCalc before a release tag. Last run: 2026-10-25, on the owner's PicoCalc (USB), under controller ruling R25: only the checks that need no API key were run. The rest are PENDING and need the owner's API keys.

Result: PASS, FAIL or PENDING.

| # | Check | Result | Notes |
|---|---|---|---|
| 1 | App installs and launches to the new-chat screen | PASS | Pushed to `/apps/.dev/llmchat` with `push_app(hidden="dev")`, started with `launch .dev/llmchat`. Opens on "Ask anything", cursor in the compose box. |
| 2 | Keys from `keys.txt` over USB are read | PASS | Dummy `claude=dummy-key-not-real` written to `/data/net.picodeck.llmchat/keys.txt`; Settings shows **Claude key** as `***************real` (masked) and OpenAI key as "not set". No real key was used. |
| 3 | A saved program runs from the Programs tab; Esc returns | PASS | `example.lua` (a counter) placed as the app saves programs (`programs/<name>.lua` plus `programs/index.json`, no owner chat). Enter ran it, Space counted, Esc returned to Programs with "example.lua ended after 15 s". |
| 4 | "Stop program" ends `while true do end` | PASS | `spin.lua` run from the Programs tab; system menu opened, waited 5 s, Enter on "Stop program": back on Programs with "spin.lua stopped after 9 s" (18 s on the first run). Menu first item is "Stop program". Done twice. |
| 5 | Lowest free heap after a program run | PASS (measured) | See "Memory" below. |
| 6 | Memory at the new-chat screen (sandbox module loaded) | PASS (measured) | See "Memory" below. |
| 7 | A real Claude chat over TLS | PENDING | needs the owner's API keys |
| 8 | A real OpenAI chat over TLS | PENDING | needs the owner's API keys |
| 9 | Streaming looks smooth | PENDING | needs the owner's API keys |
| 10 | Lowest free heap after a long real chat plus a program run | PENDING | needs the owner's API keys (item 5 covers a program run without a long chat) |
| 11 | Prompt cache: `usage.cache_read_input_tokens > 0` on a second request, for each default model (ruling R7) | PENDING | needs the owner's API keys |
| 12 | Chat ids near midnight (`getClock` fields) | PENDING | needs the owner's API keys (needs a real chat near midnight, or the device clock set) |
| 13 | The old app's key import (`Store:importOld`) on a device | PENDING | It has never run on hardware: the device copy for items 1-6 had the import removed. It copies the old app's `llmchat_api_key` to `keys.txt`, then **clears it from the old app's config**, so run it on a card whose old config can be lost (or back up `/data/<old id>/config.json` first). Check: the key lands in `keys.txt` under the right provider, Settings shows it masked, and the old keys are gone. |
| 14 | Opening a ~150 KB chat (the `LONG_BYTES` note size) | PENDING | Host: 112 ms. On the device: time from Enter in Recent chats to the chat drawn, and the free heap after. Also the save a send now makes once its request is on its way (final review I1): it should not delay the first words. That save runs in slow mode (SPI0 at 1 MHz, as every write the app makes while a request is in flight, S1), so time it as such: about 1.3-1.5 s for a 150 KB chat by the review's estimate, against 0.1-0.2 s at full speed. Needs a long chat, so a real API key (or a staged chat file). |
| 15 | Frame rate while a long program block streams | PENDING | needs the owner's API keys. A reply with a 100+ line Lua block: the live layout re-lays only the tail after the last blank line outside a fence (spec 7.4), but a block has no blank line outside a fence, so the open block is laid out again on each bump. Watch for lag on the device. |
| 16 | Program speed and memory with the run-over gate (final review C1) | PENDING | Every picocalc call a program makes now goes through a gated wrapper (one Lua call and a pcall). Host: about 140 ns a call against 30 ns direct; one run's env grew from 23 KB to 36 KB (64-bit host). On the device: `example.lua` and `dice.lua` stay smooth, a loop of 10,000 `display.fillRect` calls is timed, and items 5 and 6 are measured again. No key needed. |

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

## Not run, and why
Everything marked PENDING needs a real API key. The owner has not supplied keys, and no API spend was made (no `docs/research/api-spend.md` entries). `docs/research/2026-10-25-verify-first.md` lists the other key-dependent probes (stream latency, POST size / `LONG_BYTES`).

## Device state left
`/apps/llmchat` (the owner's installed old LLM Chat) was never touched. The test copy `/apps/.dev/llmchat` was removed. `/data/net.picodeck.llmchat/` held only `config.json` (304 bytes) before and after; the test files (`keys.txt`, `programs/`, `prefs.json`, `mem.txt`) were removed. The device is at the launcher.
