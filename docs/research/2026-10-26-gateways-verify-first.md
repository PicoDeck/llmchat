# Gateways: verify-first findings

Date: 2026-10-26. Answers the five questions in section 11 of the gateways spec (`docs/superpowers/specs/2026-10-26-llmchat-gateways-design.md`), before code depends on them.

**The device run is still to do.** The PicoCalc wasn't plugged in when these were measured, so questions 1, 2 and 5 were answered in the simulator only. Their decisions below are provisional, and two are deliberately the cautious choice. The device probe (`tools/probes/drive.py hw lists <port>`) runs with the owner's go-ahead alongside the final device checks (plan Task 12). If it changes a decision, this document gets a dated addition.

Tools:
- `tools/probes/cc.py`: one streaming Chat Completions request. It sends the firmware's `User-Agent: PicoDeck/1.0` and no `max_tokens`.
- `tools/probes/lists/`: the device probe app, driven by `tools/probes/drive.py <sim|hw> lists`.

Spend: about $0.027 for these probes. They are logged as rows starting `probe` in `api-spend.md`, which brings the project total to about $0.030.

## 1. The big lists on the device

Simulator (`drive.py sim lists`), one download at a time, drawing a spinner every frame with the app's 10 ms frame sleep:

| list | bytes | ids | time | lowest free PSRAM | fps | longest frame |
|---|---|---|---|---|---|---|
| Vercel `/v1/models` | 543,819 | 480 (all types) | 0.32 s | 7.77 MB | 60 | 17 ms |
| OpenRouter `/api/v1/models?output_modalities=text` | 791,579 | 467 | 0.30 s | 7.61 MB | 60 | 17 ms |

- Free PSRAM was 8.02 MB at the start. The lowest point during the OpenRouter download was about 400 KB below it (the 64 KB read buffer, chunks waiting for a frame, and the carried tail). The body is never held.
- The scanner found exactly as many ids as the lists have models: 480 Vercel entries and 467 OpenRouter entries. With `type: "language"` kept, 318 Vercel ids remain (laptop check).
- The device's WiFi is much slower than the laptop's, and its Lua is much slower than the simulator's. The download time and the frame rate are the numbers the device run must give.

## 2. Filtering speed

Simulator, the 947 full ids from both lists, 20 runs each of the section 5.1 filter (words, lower case, plain `string.find`, building the row tables):

| filter | matches | ms per keystroke |
|---|---|---|
| `f` | 238 | 0.2 |
| `flash` | 104 | 0.1 |
| `ds flash` | 0 | 0.1 |

This says nothing yet about the device. Its Lua ran a JSON decode in about 400 µs that takes microseconds on the laptop, so a few hundred times slower is possible. That could put the full filter near 50 ms.

## 3. No `max_tokens`

`cc.py --long`, prompt "Write a complete Lua program of about 300 lines: a Snake game for a 320x320 screen.", effort low, no `max_tokens`:

| service / model | status | finish | output tokens (reasoning) | cost |
|---|---|---|---|---|
| vercel `deepseek/deepseek-v4.1-flash-1017` | 200 | stop | 6,155 (2,435) | $0 (BYOK: billed to the owner's own DeepSeek key) |
| vercel `minimax/minimax-m3.1-flash` | 200 | stop | 5,979 (1,502) | $0.0036 |
| vercel `google/gemini-3.8-flash` | 200 | stop | 3,313 (0) | $0.0125 |
| opencode `deepseek-v4.1-flash` | 200 | stop | 7,072 (4,163) | $0.0085 |

All four finished with `stop` and well over 2,000 tokens. No service cut the reply short by a default limit.

**Found on the way:** opencode.ai sits behind Cloudflare, which answers Python's default `User-Agent: Python-urllib/3.x` with a 403 HTML page ("Access denied"). This happens for the chat endpoint and for `/inference/v1/models`. With the firmware's own `User-Agent: PicoDeck/1.0` (picodeck `src/drivers/http.c`), both work. So the app is fine as long as it doesn't override the header, but `tools/record_stream.py` must send `PicoDeck/1.0`, or it will record Cloudflare's page.

## 4. Effort on a model that doesn't reason

`cc.py`, the short question, effort `low`:

| service / model | reasoning support | status |
|---|---|---|
| vercel `mistral/mistral-small` | no `reasoning_options` in the list | 200, ignored |
| vercel `amazon/nova-micro` | no `reasoning_options` | 200, ignored |
| opencode `mistral-large-4` | not listed | **400**, body `{"object":"error","model":"mistral-large-4"}` with no message |
| opencode `mistral-large-4`, effort `medium` | | **400**, the same |
| opencode `mistral-large-4`, effort `high` | | 200 (376 reasoning tokens) |
| opencode `mistral-large-4`, no effort field | | 200 (379 reasoning tokens) |
| opencode `glm-5.3-flash`, `minimax-m3`, `qwen3.8-max`, `deepseek-v4-pro` | | 200 |
| opencode `kimi-k3` | | 403 `Upstream request failed: Model access is disabled` (the owner's account, not the effort) |

So Vercel ignores effort on models that can't use it. OpenCode's Mistral accepts only `high` (or no field), and its 400 carries no message to recognise. The other OpenCode families accept `low`. OpenRouter wasn't probed (expired key); it documents dropping parameters a model doesn't support.

Rule: a Chat Completions request that carried an effort field and got HTTP 400 is sent once more without the field. It is cheap, because a 400 arrives before any reply text, and it needs no list of which models reject what. A hand-typed bad id that also gives 400 then costs one extra failed request, which isn't billed, before the error shows.

## 5. Two connections at once

Simulator: both lists downloading together finished in 0.27 s, lowest free 7.45 MB, 60 fps, both complete (480 + 467 ids). The firmware documents up to 8 simultaneous connections. Each TLS connection on the device holds its own mbedTLS buffers, so the device run decides this.

## Decisions

```
LISTS_OK = yes              (simulator; provisional until the device run)
FILTER_MS = 0.2             (simulator; the filter narrows incrementally anyway: see below)
MAX_TOKENS = omit
EFFORT_REJECTED = opencode on mistral-large-4: HTTP 400 for effort low and medium. Rule: a CC request that carried an effort field and got HTTP 400 is retried once without it.
TWO_CONNECTIONS = no        (cautious until the device run: list downloads wait while a reply arrives)
```

- `FILTER_MS` doesn't trigger the plan's incremental filter, but the device figure isn't known. Task 9 narrows the previous result when the filter only grew, so the device needn't be measured first.
- `TWO_CONNECTIONS = no` costs little: a download waits for the reply in progress to end, and its group shows "Getting the model list..." meanwhile. If the device copes, it can be relaxed later.
