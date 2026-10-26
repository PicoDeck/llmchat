# LLM Chat 2.0: design

Date: 2026-10-25. Status: approved, built, and merged to `main` on 2026-10-26.

**Changed 2026-10-26** by [the gateways design](2026-10-26-llmchat-gateways-design.md): the direct OpenAI provider is gone; OpenCode, OpenRouter and Vercel AI Gateway are added; and an F4 model picker replaces the Provider and Model settings, with every model named `<service>/<model>`. Sections 2, 3, 4.1, 5, 6, 8, 10 and 11 below are updated to match. The gateways design has the details and the decisions behind them; where the two disagree, it wins.

A rewrite of PicoDeck's **LLM Chat** app. It chats with Claude, and with the models on OpenCode, OpenRouter and Vercel AI Gateway, streams replies, keeps recent chats, and can have the model write small Lua programs that run on the spot, inside a sandbox, without leaving the app. It moves out of the `picodeck` repo into its own repo, like PicoSurf and BRICK-15, so it ships through the App Store on its own.

Mockups of every screen, drawn by the real firmware in the simulator, are in [`docs/mockups/`](../../mockups/). The owner reviewed them and said "Everything looks good".

Decisions are tagged two ways throughout. **Owner:** the owner decided it in conversation. **Call:** the author of this document chose it, and the owner can still overrule it.

---

## 1. Why

The current app (`picodeck/apps/llmchat/main.lua`, 571 lines, from the PicOS days) is out of date:
- It parses JSON by hand and waits for a whole reply before showing any of it.
- It defaults to models from 2024. Its Claude default, `claude-3-haiku-20240307`, was retired on 2026-04-20.
- Its Claude path can't work: it sends no `max_tokens`, and it puts the system prompt in `messages` with role `system`.
- It saves five settings in `picocalc.config`, which holds four (`APPCONFIG_MAX_ENTRIES`), so one is lost silently.
- It draws plain 6x8 text with no word wrap aware of fonts, and it scrolls by hand-counted lines.

The owner wants it rebuilt on the current SDK and UI pieces, OpenAI kept, Claude added as a working option, and a way to make Lua programs on the device. **Owner:** nothing from the old app has to be kept.

## 2. Goals, non-goals, anti-goals

**Goals**
1. A quick question is fast. The app opens on a fresh chat with the cursor in the compose box. The reply streams in word by word. (**Owner:** usage is mostly quick questions, sometimes a longer back-and-forth.)
2. Claude through Anthropic's own Messages API, and any chat model on OpenCode, OpenRouter or Vercel AI Gateway through Chat Completions, picked from one list as `<service>/<model>`. **Owner** (the gateways replaced OpenAI on 2026-10-26).
3. Recent chats are kept on the SD card, in a list you can reopen and carry on from. **Owner.**
4. When the model writes a Lua program, it is saved as a file you can run from inside the app. **Owner:** a file runnable from this app is enough for now.
5. A program that crashes, hangs or calls `sys.exit()` never takes the chat app down with it. **Owner.**
6. The app lives in its own repo and installs from the App Store. **Owner.**

**Non-goals (this version)**
- Turning a program into a launcher app. **Owner:** that's a later step.
- Multi-file programs, programs with assets, programs that `require` modules.
- Images, files or voice in chats. Tool use or web search by the model.
- OpenAI's own API. **Owner:** dropped on 2026-10-26; GPT models are reachable through OpenRouter and Vercel.
- OpenAI-compatible local servers (Ollama, LM Studio). The old app had an Ollama option. **Call:** dropped. The app speaks Chat Completions to the gateways (6.3), so one could come back later as another service.
- Conversation sync or export.
- A fully isolated program runner, which would need a firmware feature (section 9.7).

**Anti-goals**: it fails even if it works when...
- The model's program can read your API keys or chats. Programs run inside the chat app's process, so this has to be designed out, not hoped away (section 9.3).
- A quick question feels slow because of the app: a long startup, a modal dialog in the way, or a lag before the first words appear that isn't the model thinking.
- Anything needs Tab. The owner finds Tab awkward on the PicoCalc keyboard. (Known from PicoSurf, where it came up.)

## 3. Constraints that shape the design

From the firmware (`picodeck/CLAUDE.md`, `src/os/CLAUDE.md`, `src/drivers/CLAUDE.md`, `docs/`):
- Lua 5.4 with `base`, `table`, `string`, `math`, `coroutine`, `utf8` only. No `io`, `os`, `debug` or `package`. `load` takes text only. So there is no instruction-count hook for programs (section 9.5).
- Numbers: 32-bit integers, `float` numbers (integers exact to 2^24). Host tests must also run under a 32-bit Lua build (section 11).
- `picocalc.config` holds at most 4 keys per app. Do not use it for this app's data (section 8).
- `ui.textInput` takes at most 128 characters, and API keys are 100-200 characters. Use the widgets library's text fields and text area instead of modal prompts.
  - Firmware releases and the store don't install `system/lib/widgets.lua`, so the app ships its own copy as `src/widgets.lua` and loads it with `require`. The header comment names the `picodeck` commit it was copied from.
- Every font covers ASCII 0x20-0x7E only. Model output is UTF-8 with curly quotes, dashes, bullets and emoji, so fold it to ASCII before drawing (section 7.3).
- At most 8 loaded fonts at a time, shared by `display.loadFont` and `graphics.font.new`. The chat uses 2 (Sans, Sans Bold) and leaves 6 for programs.
- HTTP callbacks run inside the firmware's service pass, *between any two Lua statements*. Callbacks only record what arrived; all parsing happens in the main loop (PicoSurf's `src/http.lua` follows the same rule).
- The HTTP read timeout is idle-based: it restarts whenever bytes arrive (`http.c`), so a long streamed reply never times out while data keeps coming.
- HTTPS verifies certificates against an 11-root bundle. **Checked 2026-10-25 and 2026-10-26:** `api.anthropic.com`, `openrouter.ai` and `opencode.ai` chain to **GTS Root R4**, and `ai-gateway.vercel.sh` to **ISRG Root X1**; the bundle has both. No firmware change is needed.
- A verified connection waits for SNTP to set the clock. Before that, a request fails with an error starting `clock not set`.
- `sys.exit()` is sticky: no `pcall` can catch it (`src/os/CLAUDE.md`, "App exit is sticky"). Programs must never reach the real one (section 9.3).
- FatFS allows 16 open files in total, so every file handle a program opens must be closed after it runs.

## 4. Where it lives

### 4.1 The new repo
- Local: `~/Projects/PicoDeck/llmchat` (this repo, branch `main`). GitHub: `PicoDeck/llmchat`, with the topic `picodeck-app`. Creating the GitHub repo is outward-facing: get the owner's go-ahead at that step.
- **Call:** keep the id `net.picodeck.llmchat` and the directory name `llmchat`. Existing installs then keep their data folder (`/data/net.picodeck.llmchat`), and their old API key can be imported (section 8.4).
- `app.json`:
  ```json
  {
    "id": "net.picodeck.llmchat",
    "name": "LLM Chat",
    "description": "Chat with Claude and the models on OpenCode, OpenRouter and Vercel, and have them write Lua programs you can run on the spot.",
    "version": "2.0.0",
    "author": "PicoDeck",
    "category": "network",
    "requirements": ["http"],
    "homepage": "https://github.com/PicoDeck/llmchat",
    "min_firmware": "<the first release with picocalc.json and system/lib/widgets.lua: the builder looks it up>"
  }
  ```
- Layout, after PicoSurf (`src/` modules, `tests/`, `Makefile`) and BRICK-15 (CI, packaging). **Call:**
  ```
  app.json  main.lua  icon.png  README.md  Makefile
  fonts/        sans.pfn, sans-bold.pfn, LICENSE (copied from PicoSurf)
  prompt/       system.txt, picodeck-api.md (section 10)
  src/          app.lua, http.lua, sse.lua, services.lua, providers/claude.lua, providers/cc.lua,
                chat.lua, store.lua, keys.lua, markdown.lua, layout.lua, fold.lua,
                modellists.lua, picker.lua,
                programs.lua, sandbox.lua, widgets.lua (copied: section 3), screens/*.lua
  tests/        run.lua, fakepc.lua, test_*.lua, e2e/ (pytest + fake API server)
  tools/        build_lua32.sh (from PicoSurf)
  .github/workflows/build.yml
  ```
- CI (`build.yml`, modelled on BRICK-15's): host tests under `lua5.4` and lua32, then the zip `picodeck-llmchat-<ref>.zip` with `app.json`, `main.lua`, `icon.png`, `fonts/`, `prompt/` and `src/` at the archive root. On a `v*` tag it checks that `app.json`'s version matches the tag and publishes a release with that one zip. The store needs exactly one `.zip` per release, files at the root, at most 16 MB.
- `icon.png`: **Call:** make one in the style of BRICK-15's and DOOM's.
- Only Sans and the built-in fonts, no Serif. **Call:** PicoSurf's Serif (Adobe Utopia) has an unresolved licence question about modifying it, and the chat doesn't need a second reading font.

### 4.2 Moving out of `picodeck`
Following the precedent of `picodeck` commit `ee30cb0` ("move block.exe, C-Dogs and DOOM to their own repos"):
1. Build and release 2.0.0 from the new repo.
2. **Store claims.** The store gives an id or directory name to the first repo it indexes with it, and `seed-claims.sh` gave `net.picodeck.llmchat` and `llmchat` to `PicoDeck/picodeck`. Point both claims at the new repo, or the store rejects it as `id-claimed-by:PicoDeck/picodeck`:
   ```
   npx wrangler kv key put --binding STORE_KV "claim:net.picodeck.llmchat" "PicoDeck/llmchat"
   npx wrangler kv key put --binding STORE_KV "claim:dir:llmchat" "PicoDeck/llmchat"
   ```
   Then refresh the store. These steps change live services: get the owner's go-ahead first.
3. In `picodeck`, on a branch off `develop`, delete `apps/llmchat/` in one `chore(apps): move LLM Chat to its own repo` commit. Nothing else in the tree refers to it (checked 2026-10-25: no tests, docs or release packaging mention it).

## 5. Screens and keys

The mockups in `docs/mockups/` are the reference layout:

| File | Screen |
|---|---|
| `01-new-chat.png` | A new chat, the app's opening screen |
| `02-streaming.png` | A reply arriving |
| `03-long-chat.png` | A longer conversation, scrolled |
| `04-program.png` | A reply containing a Lua program |
| `05-program-error.png` | A program that crashed |
| `06-recent-chats.png` | Recent chats (tab 1) |
| `07-programs.png` | Saved programs (tab 2) |
| `08-settings.png` | Settings (replaced by 14) |
| `09-picker.png` | The model picker (F4) |
| `10-picker-filter.png` | The picker, filtered |
| `11-picker-first-time.png` | The picker before the lists are downloaded |
| `12-new-chat.png` | A new chat, naming the current model |
| `13-chat-switched.png` | The model switch line |
| `14-settings.png` | Settings: a key per service |

Common to every screen:
- The header is `ui.drawHeader(title)`, with the clock, WiFi and battery drawn by the firmware.
- The footer is `ui.drawFooter(keys, model)`.
- UI chrome uses `FONT_6X8`. Chat text uses Sans (14 px rows); code uses `FONT_SCIENTIFICA` (6x12). After drawing anything in another font, set 6x8 back before the firmware draws its UI (PicoSurf's rule).

### 5.1 Chat screen
- **Layout.** Conversation area from y 22 to above the compose box. The compose box is a 3-row `W.TextArea` (6x8) at the bottom. Footer at y 302.
- **Your messages** are right-aligned boxes in blue (`rgb(30,58,104)`), at most 240 px wide.
- **The model's messages** are left-aligned and full width, with a 2 px bar in its service's colour: Anthropic `rgb(217,119,87)`, OpenCode `rgb(240,196,70)`, OpenRouter `rgb(120,140,255)`, Vercel `rgb(215,215,215)`. Replies from before the update keep theirs (OpenAI's `rgb(16,163,127)`).
- **The new chat intro** shows "Ask anything", the current model's full id with its service's dot, and the key caps F1 "Recent chats", F4 "Model", F5 "Settings" (mockup 12).
- **The footer's right side** shows the current model's short name, the part after its last `/` (`gemini-3.8-flash`), cut with ".." if it would reach the keys.
- **One current model** (`prefs.model`), for every chat. Sending in a chat whose last reply came from another model adds the note "now `<id>`" before the message, drawn dim and centred between two thin rules (mockup 13).
- **A reply arriving.** The spinner (`ui.drawSpinner`, radius 4) sits at the end of the text. While the model thinks before its first word, the reply shows "Thinking..." and the spinner. The view follows the reply, unless you have scrolled up; scrolling back to the bottom resumes following.
- **The scroll bar** is 2 px wide at the right edge, shown only when the conversation is taller than the view.
- **Notes** are local lines that are never sent to the model: errors ("Anthropic rejected the API key. Check Settings."), "Reply stopped", "dice.lua ended", "now vercel/google/gemini-3.8-flash". They are drawn dim, or red for errors.

| Key | Action |
|---|---|
| typing, Left/Right, Backspace, Del | edit the compose box (passed to `W.TextArea`) |
| Enter | send (nothing when empty; when the last item is an error note and the box is empty, retry) |
| Shift+Enter | new line in the compose box |
| Up / Down | scroll the conversation one row (14 px); hold to repeat |
| Shift+Up / Shift+Down | scroll a page |
| Esc | while a reply arrives: stop it. Otherwise: quit the app (the unsent text is kept as a draft for this chat) |
| F1 | Recent chats |
| F2 | new chat |
| F3 | run the newest program in this chat (only when one exists and no reply is arriving) |
| F4 | pick a model (the picker, gateways design 5.1); at any time, applying from the next message |
| F5 | Settings |

**Call:** Up/Down always scroll the conversation; the compose box's cursor moves with Left/Right only. Messages are short, and scrolling is the frequent action.

### 5.2 Recent chats and programs
- `ui.drawTabs` with "Chats" and "Programs"; Left/Right switch tabs.
- Two-line rows, 32 px each, with the selected row on `rgb(40,70,130)`:
  - Chats: the title in Sans; a 6x8 line with the service's label ("Vercel"; "Anthropic" for chats from before the update, "OpenAI" for OpenAI ones) and the message count (plus "N programs" when there are any); the age at the right; a service-colour dot at the left.
  - Programs: the file name; "from <chat title>" and the size; the age.
- Chats keys: Enter opens, F2 new chat, Del deletes (after `ui.confirm`), Esc back to the chat.
- Programs keys: Enter runs, F4 opens the chat that made it, Del deletes (after `ui.confirm`), Esc back.
- Age format: "2m", "1h", today "14:02", "Yest", weekday within 7 days, then "18 Oct".

### 5.3 Program error screen
Mockup 05.
- `ui.drawPanel` titled "Program stopped", with the error message in red (wrapped to 6x8 columns), how long the program ran, and up to the last 5 lines it printed.
- Buttons "Ask the model to fix" (focused) and "Back to chat". The hint above them names the current model's short name: "`gemini-3.8-flash` can see the error and the code and send back a fixed version." The fix goes to the current model.
- Keys: Left/Right move between the buttons, Enter chooses, F3 runs the program again, Esc goes back to the chat.

### 5.4 Settings
Mockup 14 (gateways design 5.4). Two dim section labels, each with a thin rule, and seven rows:

| Section | Row | Widget | Notes |
|---|---|---|---|
| API keys | Anthropic, OpenCode, OpenRouter, Vercel | text field, masked | the known prefix (`sk-ant-`, `sk-or-v1-`, `sk-`), then `*` and the last 4 characters; Enter edits in clear text; an empty key removes it |
| Replies | Thinking | `W.Select` | Low (default) / Medium / High: each service's effort field (6.2, 6.3) |
| | Reply font | `W.Select` | Sans (default) / System (6x8) |
| | Instructions | `W.TextArea`, 3 rows | added to the system prompt. Default: "Keep answers short: I'm reading on a 320 px screen." |

- The model is picked with F4 in the chat (5.1), not here. The section labels can't be focused; Up and Down skip them.
- Key fields accept up to 512 characters.
- `prefs.json` also takes four hidden overrides, `anthropic_base`, `opencode_base`, `openrouter_base` and `vercel_base`. The e2e tests use them to reach a local fake server (section 11); each replaces its service's chat host and model-list host.
  - Only `http://127.0.0.1:<port>` and `http://localhost:<port>` are accepted; anything else is ignored (9.3).
  - They have no row in Settings.

- Below the rows, a dim note: "Keys are long to type: you can also put them in keys.txt in the app's data folder."
- Keys: Up/Down move between rows, Enter edits or changes a row, Esc saves and goes back.
- `W.TextField` has no masking, so the key fields draw their own masked text when not being edited.

## 6. Providers

### 6.1 Common shape
Each provider module turns the neutral conversation into a request, and stream events into neutral calls:
```lua
-- One module per kind of API: src/providers/claude.lua (the anthropic service) and
-- src/providers/cc.lua, built once per gateway from its row in src/services.lua.
-- request(json, items, opts) -> path, headers, body     opts = {key, model, effort, system}
--                                                       (model: the id after the service part)
-- parser(json, handlers) -> feed(event_name, data_string), finish()
--   handlers.text(delta)            visible text
--   handlers.thinking()             the model is thinking (show "Thinking...")
--   handlers.done(info)             info = { stop = "end"|"length"|"refusal"|..., raw = <Claude blocks to store>, usage = {...} }
--   handlers.error(message)         an error event in the stream
--   finish()                        the chat calls it when the connection ends (a CC stream
--                                   closed after its finish reason is complete; Claude's no-op)
-- titleRequest(json, key, firstUser, firstReply, model), titleText(json, body),
-- describeError(json, status, body, retryAfter)
-- retryNoEffort(status)             CC only: true for a 400 (6.3)
```
- `src/sse.lua` parses Server-Sent Events from arbitrary chunk boundaries:
  - LF and CRLF line endings; `event:` and `data:` fields; multi-line data joined with `\n`.
  - Lines starting `:` (comments, keep-alives) are ignored.
  - An event is dispatched on a blank line.
- `src/http.lua` wraps `picocalc.network.http` for one streaming POST (and a GET, for the gateways' model lists, gateways design 8):
  - Setup: `setReadBufferSize(512 * 1024)`, or `64 * 1024` when that is refused; `setConnectTimeout(20)`, `setReadTimeout(120)` (idle-based; long enough for a model thinking before its first word).
    - Why 512 KB (changed 2026-10-26): the buffer holds what arrives while the app isn't reading, and the device's TCP has no receive window, so a full buffer fails the reply. A gateway streams a reasoning model as one event of about 325 bytes per token, 60-85 KB/s, which filled 64 KB in under a second of the app being busy (a card write at send).
  - Callbacks only append `conn:read()` chunks to a list and set flags. The main loop drains the list into the SSE parser every frame.
  - A non-200 status means the body is a JSON error, not a stream: read it whole and decode it (section 6.4).
  - Esc calls `conn:close()`.
- JSON goes through `picocalc.json.encode` / `decode`. No hand-built JSON.

### 6.2 Claude
- `POST https://api.anthropic.com/v1/messages`. Headers: `content-type: application/json`, `x-api-key`, `anthropic-version: 2026-10-21`.
- Body:
  ```json
  {
    "model": "claude-opus-5-5",
    "max_tokens": 32000,
    "stream": true,
    "cache_control": {"type": "ephemeral"},
    "system": "<section 10>",
    "output_config": {"effort": "low"},
    "messages": [ ... ]
  }
  ```
  - **Call:** `max_tokens` 32000 caps a runaway reply while leaving room for long programs.
  - Top-level `cache_control` caches the stable prefix: the system prompt and the API cheat sheet.
  - Do not send `temperature`, `top_p` or `top_k`: API version `2026-10-21` rejects them on every model.
  - Do not send `thinking`: the current models think adaptively by default, and `{type: "disabled"}` is a 400 on Opus 5.5 and Sonnet 5.5. Thinking depth comes from `effort` (the Thinking setting).
- **Models** (built-in list, from Anthropic's model table as of 2026-10-06):

  | Label | Id | $/MTok in / out | Notes |
  |---|---|---|---|
  | Opus 5.5 | `claude-opus-5-5` | 4 / 20 | **the default**: Anthropic's recommended default model |
  | Sonnet 5.5 | `claude-sonnet-5-5` | 2 / 10 | |
  | Haiku 5.5 | `claude-haiku-5-5` | 0.10 / 0.50 | no server-side refusal fallback |
  | Fable 5.1 | `claude-fable-5-1` | 10 / 50 | most capable; slowest |

  - **Call:** the mockups show Sonnet 5.5, but the default is Opus 5.5 at Low thinking (`anthropic/claude-opus-5-5`). A quick question costs about 1-2 cents with the cached prompt. The owner can pick another model with F4.
  - The list is in `src/providers/claude.lua`, the picker's Anthropic group; a newer model can be typed whole in the picker (`anthropic/<id>`).
- **Streaming events.** Text appears from `content_block_delta` / `text_delta`. A `content_block_start` of type `thinking` calls `handlers.thinking()`. Display defaults to `"omitted"`, so thinking text is empty; only the signature matters.
- **Raw blocks** (must get right):
  - Rebuild each assistant message's full `content` array from the stream: `thinking` blocks with their `signature` (from `signature_delta`), `text` blocks, and `fallback` blocks.
  - Store the array with the message, and send it back unchanged on every later request, even after a model change. The API drops, unbilled, any block the current model can't read.
  - History must be **append-only**: an edited earlier turn invalidates thinking blocks, and accounts created on or after 2026-08-31 get a 400. The app never rewrites a sent message.
  - Replies from the gateways (and old OpenAI ones) go to Claude as plain text. Items from before the update say `provider: "claude"`; their raw blocks go back too.
- **Refusals.**
  - Send `"fallbacks": "default"` with the header `anthropic-beta: server-side-fallback-2026-07-01` for Opus 5.5, Sonnet 5.5 and Fable 5.1, but not Haiku 5.5. On a policy decline, the API then runs a fallback model on the same stream.
  - A `fallback` block marks the switch point. When storing a message that has one, drop any `thinking` / `redacted_thinking` block before the last `fallback` block (the echo rule).
  - `stop_reason: "refusal"` on the final `message_delta` means the whole chain declined. Keep any partial text, and add the note "<model> declined to answer this."
  - Branch on `stop_reason`, never on `stop_details`.
  - **Call:** fallbacks are on by default. Tell the owner, and drop them if the owner declines.
- **Stopped replies.** When Esc stops a reply, keep the text received so far as the assistant message, marked `stopped`. Drop any incomplete thinking block (it has no signature yet). The message is sent back later as plain text.
- `stop_reason: "max_tokens"` adds the note "Reply cut off at the length limit."

### 6.3 Chat Completions (the gateways)
OpenAI's own API was dropped on 2026-10-26. The three gateways (OpenCode, OpenRouter, Vercel AI Gateway) speak Chat Completions, served by one module, `src/providers/cc.lua`, built from each service's row in `src/services.lua`. Gateways design 6 has the whole contract; in short:
- `POST <base><chat path>` with `Authorization: Bearer <key>`, `stream: true`, `stream_options: {include_usage: true}`, and the system prompt as the first `messages` entry. Every earlier reply goes as plain text; Claude's raw blocks stay with Anthropic.
- Effort: OpenRouter and Vercel send `reasoning: {effort}`, OpenCode `reasoning_effort`. No `max_tokens`: each model's own limit applies (checked in the gateways' verify-first: long programs finish).
- A model that rejects the effort field (OpenCode's Mistral answers HTTP 400 to every effort but high) gets the request once more without it.
- The stream is `data:` JSON chunks ending with `[DONE]`; reasoning arrives in `reasoning`, `reasoning_details` or `reasoning_content` and only shows "Thinking...". A stream that closes after its finish reason without `[DONE]` is complete. `content_filter` is a refusal; OpenRouter's mid-stream `error` chunk is an error.
- Titles: a non-streaming request to the chat's own model, `max_tokens` 300, effort low.
- Keys are accepted up to 512 characters, unchecked. Each key goes only to its own service's host (or the loopback test override, 5.4).

### 6.4 Errors
Each failure becomes a note in the chat. The last request can be retried by pressing Enter on an empty compose box.
- No WiFi (`network.getStatus()` not connected): "No WiFi."
- `clock not set`: retry once by itself after 3 s, then show "The clock isn't set yet; try again in a moment."
- TLS errors: show the firmware's message.
- No key for the current model's service: "Add your `<Label>` key in Settings (F5), or pick another model (F4)."
- The HTTP status decides, never the body's `error.type` (OpenCode's 401 says `server_error`):
  - 401: "`<Label>` rejected the API key. Check Settings." (Anthropic: 401 and 403.)
  - 402 (gateways): "Your `<Label>` account is out of credit."
  - 403 (gateways): "`<Label>` refused this request." (OpenRouter's moderation and budget limits.)
  - 429: "Rate limited; try again in a moment", plus the `Retry-After` seconds when the header is present.
  - 5xx and 529 overloaded: "`<Label>` is busy; try again."
  - Anything else: "`<Label>`: HTTP `<status>`." (a typed model id the service doesn't know lands here).
- Error bodies: Anthropic's is `{"type":"error","error":{"type","message"}}`, the gateways' `{"error":{"message",...}}`. Show the `message` under the friendly line.
- A connection lost mid-reply: keep the partial text, marked as interrupted.
- An `error` event mid-stream: same as a lost connection.

## 7. Rendering

### 7.1 Fonts and measuring
- Load `fonts/sans.pfn` and `fonts/sans-bold.pfn` once at start.
- Measure each character's advance once per font, as PicoSurf's `src/fonts.lua` does, and wrap by pixel width from the advance tables. No `textWidth` calls per word in the hot path.
- "System (6x8)" uses `FONT_6X8` for message text, with 10 px rows.

### 7.2 Markdown subset
`src/markdown.lua` turns message text into blocks, and works on partial text while a reply streams:
- Paragraphs.
- Headings (`#` to `###`, drawn in bold).
- Bullets (`-`, `*`, `+`, with nesting by indent) and numbered lists.
- Fenced code blocks: a panel with a title bar showing the info string or file name; lines wrap at the panel width with a dim mark at the right edge (mockup 04).
- Block quotes (dim, with a bar).
- Tables: kept as monospace text.
- Horizontal rules.

Inline:
- `**bold**` and `__bold__` switch to Sans Bold.
- `` `code` `` is drawn in green (`rgb(150,220,150)`).
- `*italic*` is drawn as plain text, since there is no italic font.
- Links show their text only.

### 7.3 Folding to ASCII
- Before parsing, fold UTF-8 to printable ASCII. Copy PicoSurf's `src/fold.lua` (proxy-compatible table: curly quotes, dashes, ellipsis, bullets, NBSP, common symbols).
- Anything else becomes `?`.
- The system prompt also asks the model for plain ASCII.

### 7.4 Layout cache and redraw
- Each message caches its laid-out rows for the current font and width.
- While a reply streams, only the last message is laid out again, and only from its last complete paragraph.
- Redraw only when something changed: new text, a key, or a spinner tick every 100 ms.
- Each frame draws only the rows in view.

## 8. Storage

Everything lives in `/data/net.picodeck.llmchat/`, written with `picocalc.fs` and `picocalc.json`.

**Safe saves.** FatFS's rename fails when the destination exists, so `fs.rename` can't replace a file in one step. A save goes:
1. Write `<file>.tmp`.
2. Delete `<file>`.
3. Rename `<file>.tmp` to `<file>`.

On load, if `<file>` is missing but `<file>.tmp` exists, finish the rename. A power cut at any point then leaves a whole file.

### 8.1 Files
| Path | Contents |
|---|---|
| `prefs.json` | the current model (`model`, a full id), the recent models (`recent`, up to 8, newest first; left out while empty), thinking, font, instructions, last open chat id, drafts by chat id, and the hidden test overrides (5.4). An old file is moved over on load: `models.claude` becomes `anthropic/<id>`, `claude_base` becomes `anthropic_base`, and `provider`, `models`, `openai_base` go |
| `keys.txt` | `anthropic=`, `opencode=`, `openrouter=` and `vercel=` lines; `#` starts a comment; editable from a computer over USB or in the Text Editor app. `claude=` is read as `anthropic=` (an `anthropic=` line wins); `openai=` is ignored, and dropped when Settings saves |
| `models/<service>.txt` | a gateway's model list: `# fetched <epoch>`, then one id per line without the service part (gateways design 8.4) |
| `chats/index.json` | `[{id, title, provider, model, created, updated, count, programs}]`, newest first |
| `chats/<id>.json` | one chat (8.2) |
| `programs/index.json` | `{ [name] = {chat, created, updated, size} }` |
| `programs/<name>.lua` | a program; `<name>.lua.prev` keeps the version before the last fix |
| `programs/<name>.data/` | that program's own files and settings (section 9.3) |

### 8.2 Chat file
```json
{ "v": 1, "id": "20261025-140212-3", "title": "Dice roller", "created": 1792908000, "updated": 1792908132,
  "items": [
    { "role": "user", "text": "make me a dice roller" },
    { "role": "assistant", "provider": "anthropic", "model": "anthropic/claude-opus-5-5",
      "text": "Here's a dice roller...", "raw": [ ...Claude content blocks... ], "stopped": false },
    { "role": "note", "kind": "program", "text": "dice.lua ended after 12 s" },
    { "role": "note", "kind": "model", "text": "now vercel/google/gemini-3.8-flash" }
  ] }
```
- `note` items are local and never sent.
- `provider` is the service id and `model` the full id. Items from before the update say `claude` or `openai` with a bare model id; they read as `anthropic/<id>` and `openai/<id>`.
- `raw` holds Claude's own blocks, sent back only to Anthropic (6.2).
- Ids come from the clock (`sys.getClock()`) when it is set, and otherwise from a counter kept in `prefs.json`.
- **Titles: Owner: tidy short titles**, as in the mockups ("how many cups in a litre?" becomes "Cups in a litre").
  - Until the title arrives, the chat shows the first user message, cut at a word to 40 characters.
  - **The request.** When a new chat's first reply completes, send one small non-streaming request to the chat's service:
    - Anthropic: `claude-haiku-5-5`, `max_tokens` 200, effort `low`.
    - A gateway: the chat's own model, `max_tokens` 300, effort low (gateways design 6.4).
    - Prompt: "Write a title of 2 to 5 words for this chat. Reply with the title only." Then the first user message and the first reply, each cut to 1,000 characters.
    - Cost: well under a tenth of a cent per chat.
  - **The result.** Fold the reply to ASCII, strip surrounding quotes and trailing punctuation, cap it at 40 characters, then update the header, the chat file and `chats/index.json`.
  - **Failure.** If the request fails, or there is no key for that service, keep the cut first message and don't retry.
  - **Conflicts.** Starting a program cancels a pending title request. It is sent again after the chat's next reply.
- **Call:** keep the 50 most recently updated chats and delete older ones when a new chat is saved. The owner raised no objection to 50.
- **Call: programs outlive their chats.**
  - Neither the cap nor Del on a chat deletes programs. A program is deleted only from the Programs tab.
  - When its chat goes, its index entry's `chat` becomes `null`, and the Programs tab shows "from a deleted chat".
  - Del on a chat that made programs confirms with "Delete this chat? Its programs are kept."
- A chat is saved after every completed or stopped reply and every note. The draft is saved on exit.

### 8.3 Long chats
- Every request resends the whole history. **Call:** past about 150 KB of history, show the note "This chat is getting long; F2 starts a new one."
- Keep sending as long as the firmware accepts the POST body. The builder measures the largest POST the device can send (section 12).

### 8.4 Importing from the old app
On first start, if `picocalc.config` still holds `llmchat_api_key`:
- Copy it to `keys.txt` as `anthropic=` if `llmchat_provider` is 2. A provider-1 key is an OpenAI key and is not imported (gateways design 9.5).
- Ignore Ollama (provider 3); its endpoint was the old native `/api/chat` path, which isn't compatible.
- Then clear the old keys and save.

## 9. Programs and the sandbox

### 9.1 What counts as a program
- A fenced code block whose info string starts with `lua`, and whose first line is a comment naming the file: `-- dice.lua` (an optional `: description` may follow).
- The system prompt tells the model this rule (section 10). Other Lua snippets in explanations are just code blocks.
- **Name rules:** lower-case; keep `[a-z0-9_-]`; at most 24 characters before `.lua`. If the comment is missing or invalid, it isn't a program.
- **Saving:** when a reply finishes (or is stopped after the block closed), each program block is saved to `programs/<name>.lua`.
  - A block from the chat that owns the name (`programs/index.json` `[name].chat`) overwrites the file, after moving the old one to `.prev`. That's what a fix does.
  - The same name from any other chat gets a numbered name: `dice-2.lua`.
  - An orphan program, whose chat was deleted, is owned again only through 9.6.
- The code panel's action line shows "F3 Run · saved as dice.lua" (mockup 04).

### 9.2 Running one
`src/sandbox.lua`, called from F3 or the Programs tab:
1. **Refuse** if a reply is still arriving: its HTTP callbacks would run inside the program. Cancel a pending title request (8.2).
2. **Read** the file. Run `collectgarbage("collect")` and drop the chat's layout caches, to leave the program as much memory as possible.
3. **Compile** with `load(src, "=" .. name, "t", env)`. A syntax error goes straight to the error screen.
4. **Prepare.** Register the "Stop program" system-menu item (9.5) and note the start time.
5. **Run** under `xpcall(fn, handler)`. The handler records `tostring(err)`; there is no traceback, because `debug` is blocked. The message carries `name:line`.
6. **Clean up** (9.4), then remove the menu item.
7. **Drain input.** Discard pending keys and events, so the Esc that ended the program doesn't also act in the chat.
8. **Report.** On a normal return or a program `sys.exit()`, add the note "dice.lua ended after N s". On an error, show the error screen (5.3).

### 9.3 The program's world
`env` is a fresh table for every run.

**Globals passed through:** `assert error ipairs next pairs pcall xpcall select tonumber tostring type rawequal rawget rawset rawlen setmetatable getmetatable collectgarbage`.

**Library tables are copied, not shared.** `math`, `string`, `table`, `utf8` and `coroutine` are fresh shallow copies for every run, so a program that replaces `string.format` changes only its own copy.
- At app start, the chat sets `__metatable = false` on the string metatable. Then `getmetatable("")` can't reach the real `string` table; method calls like `s:upper()` still work.
- As a backstop, the runner snapshots those five real tables before each run, and puts back any field that changed afterwards.

**Globals changed:**
- `_G` is `env`.
- `print(...)` writes to `sys.log` and keeps the last 5 lines for the error screen.
- `load(chunk, name, mode, e)` forces mode `"t"` and defaults `e` to `env`. Otherwise a program could load code that sees the chat app's globals.
- `require` and `dofile` are absent.
- `APP_DIR` is the program's data folder, `APP_NAME` is the file name, and `APP_ID` is the chat app's id.

**`picocalc` is an allowlist, not a pass-through.** The program's `picocalc` holds only functions and constants that have been audited (9.4's table). Anything not on the list is absent, so a new firmware API is closed to programs until it is audited.
- Each module is a plain table of copied entries, or wrappers where needed. Any metatable involved is locked with `__metatable = false`, so `getmetatable` never hands back a real module.
- **Every function in any module that takes a path** goes through the same path check as `fs`. That includes image and font loading, sound and file players, zip, `crypto.sha256File`, video, and game saves. It is the route most likely to be missed, so 9.4's table has a column for it.

Overrides:
- **`sys.exit()`** raises a private sentinel table that the runner recognises as "the program ended". This is the essential override, because the real one would close the whole chat app.
- **`fs.*`** only reaches `programs/<name>.data/`. Relative paths resolve there. Any other path, including the chat's files and `keys.txt`, gets `nil, "access denied"`. `fs.appPath(n)` returns a path in that folder, `fs.browse` is absent, and `fs.open` handles are tracked.
- **`config` and `appconfig`** are a store of the program's own, in `programs/<name>.data/config.json`, with the same calls as the real one. The real one holds the chat's data (nothing secret after section 8, but still the chat's).
- **`sysconfig`** is absent. The chat app doesn't have that requirement anyway.
- **Tracked creators.** These calls record what they return, so 9.4 can release it: `display.loadFont`, `graphics.font.new`, `network.http.new`, `tcp.new`, `sys.addMenuItem`, and the sound and player constructors.
- **`display.unloadFont`** works only on ids the program loaded, so it can't unload the chat's fonts.
- **`sys.removeMenuItems`** removes the program's items only.
- **`sys.loadlib(name)`** reads `/system/lib/<name>.lua` as text and loads it with `load(src, name, "t", env)`, so a library sees only the program's `picocalc` and file access. Passing the real `loadlib` through would let `download.toFile` write anywhere the chat can, `prefs.json` included.

**The key stays out of reach.** These are the routes from a program to an API key, and how each is shut. Keep this list current as the code changes:
- **`keys.txt` or `prefs.json` on the card:** every file path is checked, in every module.
- **The chat's globals and modules:** a separate `env`, a `load` that defaults to it, no `require`, and copied library tables.
- **Redirecting the chat's next request:** the hidden base overrides (5.4) accept only `http://127.0.0.1:<port>` or `http://localhost:<port>`, so even a tampered `prefs.json` can't send a key to another machine.
- **A request in flight:** a program can't run while a reply is arriving (9.2).
- **Program code after the run** (final review C1): a run-over gate closes the moment the program is over. From then on every function the program could hold does nothing (every `picocalc` function, pass-throughs included, `print`, the sandbox's own functions and every proxy method), and every function it handed to the firmware (menu items, HTTP, TCP and player callbacks) runs none of its code. HTTP connections, TCP sockets and the framebuffer handle are proxies for this. So a callback that fires after the run can't read the screen or the keyboard, or send anything.

### 9.4 Cleanup after every run
The firmware's launcher resets a list of things between apps (`src/os/CLAUDE.md`, "Exit teardown"). A program never exits the app, so the runner does the Lua-visible equivalent itself:
- **Display:** `clearClipRect()`, scroll offset 0 and the full scroll area, the chat's font, and the brightness saved before the run.
- **Fonts:** unload every font the program loaded.
- **Files:** close every tracked handle. Set the SD card's bus back to full speed (`fs.setSlowMode(false)`, the firmware's default, as it can't report the mode): the download library slows it while it writes, and a program can end mid-transfer.
- **Network:** close every tracked HTTP connection and TCP socket.
- **Audio:** stop tones, players and streams.
- **System:** resume background work if the program paused it (`sys.pauseBackground`); reset the frame-rate target (`perf`); remove the sprite display list (`graphics.sprite.removeAll()`).
- **Menu:** remove the program's menu items.
- **Memory:** `collectgarbage("collect")`.

The builder writes the complete list by going through every `docs/API-*.md` in `picodeck`. For each function, record:
- whether programs get it at all (the allowlist in 9.3);
- whether it takes a path, and so is wrapped with the path check;
- whether it changes state outside the program's own objects, and so is wrapped, reset afterwards, or recorded as harmless.

Keep that table in `src/sandbox.lua`'s header comment. A host test checks the program's `picocalc` against it.

### 9.5 Stopping a hung program
`debug` is blocked, so the app can't interrupt a loop by itself. The firmware's service hook still runs every millisecond, though, and the Sym key opens the system menu from inside any loop.
- Before each run, the chat adds a menu item, **"Stop program"**, with `sys.addMenuItem`.
- Its callback raises the stop sentinel. The firmware runs item callbacks after the menu closes, "and they may leave by longjmp (`sys.exit()`, a Lua error)" (`src/os/CLAUDE.md`, "App item callbacks run last"). The error should therefore unwind the running program up to the runner's `xpcall`.
- **Verify this first** on the simulator and the device, with `while true do end` and with a loop that calls only `sys.sleep` (section 12).
- **Limits:** a program can still swallow the stop; 9.7 lists the ways (its own `pcall` is the simplest). The system menu's "Exit App" remains as a last resort, except in the one case 9.7 names (a callback the firmware's hook fires that never returns). It closes the chat app, which loses nothing, since the chat is already saved.

### 9.6 Fixing a crash
"Ask the model to fix" appends a user message and sends it to the current model. The code is already in the conversation, so it isn't resent, and history stays append-only (6.2):
```
dice.lua stopped with an error:
dice.lua:12: attempt to concatenate a nil value (local 'b')
It printed:
<last lines, if any>
Please send a fixed version of the whole program.
```
- A program run from the Programs tab opens its chat first.
- If that chat was deleted, start a new chat whose first user message holds the program text in a ```lua block, then the error. The new chat becomes the program's owner (`index[name].chat`), so the fix saves over the same file.
- The fixed version saves over the file (9.1), and the action line offers F3 again.

### 9.7 Limits, and the stronger option for later
This is a fence, not a wall:
- A program shares the chat's Lua heap.
- It can still draw over the screen, play sound, or use the network with the chat's `http` permission.
- A program written to catch errors can ignore "Stop program": its own `pcall` or `xpcall`, `coroutine.resume` and `coroutine.close`, and the firmware's protected calls of the callbacks it runs from `sys.sleep` or a copy or unzip progress loop all catch the stop. So does a `load` reader, but it fails closed: Lua runs the runner's message handler for the reader's error, so the gate closes and the program runs on with no capabilities.
- So can a program whose `<close>` handlers each declare another `<close>` variable before they loop. Lua runs every pending handler as the stack unwinds, catching each one's error, so each Stop ends only the handler that is running (Stop raises until the run's `xpcall` returns, so one looping handler ends after one Stop).
- Exit App is the fallback for all of these, but not for this one, not yet checked on the device: the firmware's service pass, run from the Lua hook, also fires HTTP, TCP and sound callbacks (`lua_service_full`), and Lua runs no hook inside a hook. A program callback fired there that never returns gets no service pass, so the system menu can't open: neither Stop program nor Exit App can reach it, and the watchdog probably resets the device. `docs/follow-ups.md` has it as an investigation.

The real wall would be a firmware feature: run a program as its own app in its own VM, then return to the chat. The OS would do the full teardown. That fits the later "turn a program into an app" step, so it is out of scope here.

## 10. The system prompt

`prompt/system.txt` + `prompt/picodeck-api.md`, assembled in a fixed order so the prefix stays byte-identical between requests and caches:
1. **Setting:** "You're chatting with someone on a PicoCalc, a handheld with a 320x320 screen (about 50 characters a line) and a small keyboard. Answer briefly unless asked for more. Use plain ASCII: no emoji, curly quotes or special symbols. Markdown works: headings, bold, lists and code blocks."
2. **Programs:**
   - When asked for a program, write one complete Lua 5.4 file in a single ```lua block whose first line is `-- <name>.lua`.
   - The rules: one file; no `require`, `io`, `os` or `debug`; a main loop that calls `input.update()`, draws, `display.flush()`, and returns when Esc is pressed; integers are 32-bit and numbers are single-precision floats; text is ASCII; keep it under about 200 lines unless asked; use `APP_DIR` for any files.
   - A short example program.
3. **API cheat sheet** (`prompt/picodeck-api.md`): the subset of `picocalc.*` a program gets (9.3).
   - Hand-condensed from `picodeck/docs/API-*.md`, one line per function with its signature, plus constants (buttons, colours, fonts) and screen facts.
   - **Call:** about 3-4K tokens, which is over every model's cache minimum.
4. **The owner's instructions** from Settings, last, because they change most often.

Claude gets this as `system`; the gateways get it as the first `messages` entry (6.3).

A test keeps the cheat sheet honest: every `picocalc.x.y` it names must appear in `$PICODECK_ROOT/docs/API-*.md`. The test skips when `PICODECK_ROOT` is unset, as PicoSurf's does. An e2e test runs the example program from the prompt in the simulator.

## 11. Testing

**Real API use. Owner: the builder may use the owner's keys** (Anthropic, OpenCode, OpenRouter, Vercel), for about $2 in total, mostly on cheap models (Haiku 5.5, DeepSeek V4.1 Flash). Every request is logged in `docs/research/api-spend.md`.
- **Where the keys live:** ask the owner where they are, and keep the builder's copy outside the repo in `~/.config/llmchat/keys.txt` (mode 600), as PicoSurf keeps its proxy token. Never commit a key.
- **Recording:** `tools/record_stream.py <anthropic|opencode|openrouter|vercel> <case>` sends a real request and saves the raw reply to `tests/fixtures/<service>-<case>.sse` (Anthropic's keep their `claude-` names), with ids and anything key-like removed. Anthropic: text, thinking, max_tokens, title, 401. Gateways: text, reasoning, length, title, 401. OpenRouter's streams are hand-written until its key is renewed.
- **Hand-written cases:** a refusal and a mid-stream fallback can't be triggered on demand. Write those fixtures by hand from the API docs, and mark them so in their file names.
- **Device checks:** the builder runs the checks in section 12 and the release checklist with these keys, keeping a running total of what was spent.

**Host tests** (`make test`: `lua5.4 tests/run.lua` and `build/lua32 tests/run.lua`, PicoSurf's pattern, fake `picocalc` in `tests/fakepc.lua`):
- **SSE:** every split of a recorded stream across chunk boundaries; CRLF; comments; multi-line data.
- **Claude parser:** recorded streams for text, thinking + signature, fallback mid-stream, refusal, max_tokens, an error event. Check the stored `raw` against the echo rule.
- **Chat Completions parser:** the recorded Vercel and OpenCode streams and the hand-written OpenRouter ones, split at every chunk size; usage with and without `choices`; a stream closed after its finish reason without `[DONE]`; OpenRouter's mid-stream error.
- **Request builders:** golden JSON for Anthropic and each gateway, including Claude replies (with raw blocks) and old OpenAI replies sent to a gateway as plain text. Under lua32, check that integers encode without `.0`.
- **Model lists and the picker:** the list scanner on fixtures cut from the real lists at every split, an escaped `"id"`, each service's keep rules, bounded memory on a 2 MB list; the picker's groups, word filter (literal, never a pattern), the "Use" row and selection.
- **Markdown and layout:** blocks, inline bold and code, partial text while streaming, folding, wrap by advance table, code-line wrap marks.
- **Program extraction:** names, collisions, the same name in the same chat (`.prev`), invalid headers, snippets ignored.
- **Store:** index order, the 50-chat cap, atomic writes, drafts, the old-config import.
- **Sandbox** (with fakes):
  - Globals don't leak in either direction.
  - `getmetatable(picocalc.sys)` doesn't reveal the real module.
  - The `sys.exit` sentinel ends the run cleanly.
  - `fs` refuses `../`, absolute paths outside the folder, and `keys.txt`. So does every other path-taking function on the allowlist (one test per function, generated from 9.4's table).
  - A program's `string.format = nil` doesn't reach the chat, and `getmetatable("")` returns `false`.
  - `sys.loadlib("download")` gets a library that can only write inside the program's folder.
  - A non-loopback `<service>_base` in `prefs.json` is ignored.
  - `load` without an env gets the program's env.
  - Tracked fonts, files and connections are released.
  - `unloadFont` refuses the chat's fonts.

**Simulator e2e** (`make e2e`, pytest + `picodeck/tests/e2e/picodeck_simulator.py`):
- A fake API server, `tests/e2e/fake_api.py`, routes by path to the four services and replays their recorded streams (and non-streaming title replies), and serves the three model lists, on `127.0.0.1`. The app reaches it through the hidden `<service>_base` overrides in `prefs.json`; the simulator's HTTP is libcurl, so plain `http://` to localhost works.
- **Cases:**
  - Send and stream (screenshot checks of the reply and spinner).
  - Esc stops a reply.
  - A 401 shows the right note; Enter retries.
  - Recent chats: open, delete.
  - Settings save the four keys.
  - F4 opens the picker, typing filters it, Enter picks; a gateway reply streams; sending after a switch adds the "now `<id>`" line; a gateway 401 shows the right note; an old Claude chat (with raw blocks) goes on.
  - A program is saved, F3 runs it, and Esc returns to the chat.
  - A program that errors shows the error screen, and "Ask to fix" sends the right message.
  - A program calling `sys.exit()` returns to the chat, and the app is still running.
  - "Stop program" from the system menu ends `while true do end`.
  - A program that loads fonts and opens files leaves nothing behind (run it 10 times; the chat still draws and files still open).

**Device checks** (a short checklist in the README, run before the release tag):
- A real chat on each keyed service over TLS (Anthropic, OpenCode, OpenRouter, Vercel).
- Downloading each model list (the time, the lowest free heap), filtering about 700 ids, and the switch line.
- Streaming looks smooth.
- "Stop program" works.
- Keys from `keys.txt` over USB are read.
- The lowest free heap after a long chat plus a program run.

## 12. Verify first

The builder starts with these, because each could change the design. (The gateways' own verify-first questions and answers are in `docs/research/2026-10-26-gateways-verify-first.md`.)
1. **"Stop program" via a menu-item callback** raising an error out of a tight loop and out of `sys.sleep`, in the simulator and on the device. If it can't, fall back to documenting Sym → Exit App, and look at a small firmware change (for example, a `sys.setInterruptKey`-style hook) as a separate request to the owner.
2. **Streaming delivery on the device.** Do SSE chunks reach `setRequestCallback` promptly (TLS records of a few hundred bytes), or does anything buffer them?
3. **The largest POST body the device sends** (try 64, 256 and 512 KB). That sets the long-chat threshold in 8.3.
4. **`picocalc.json.decode` cost** for a few hundred small events a second on the device.

## 13. Left to the builder
- Module boundaries inside `src/`, and how much of PicoSurf's code to copy (`fold.lua`, `fonts.lua` measuring, `wrap.lua`, the `http.lua` patterns, `build_lua32.sh`). Copying is fine: same owner and licence.
- How the screens share state, and the input plumbing (`input.pollEvent` gives Shift for Shift+Enter; the widgets take `(btns, ch)`).
- Exact colours and spacing beyond the mockups.
- The README: what the app does, the keys, `keys.txt`, the sandbox's limits (9.7), and the device checklist.
- `min_firmware` in `app.json`.
