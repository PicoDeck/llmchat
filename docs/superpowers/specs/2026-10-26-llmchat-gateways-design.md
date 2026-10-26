# LLM Chat: gateway services and the model picker

Date: 2026-10-26. Status: reviewed by a builder check, approved by the owner, and built on branch `feat/gateways` (plan: `docs/superpowers/plans/2026-10-26-llmchat-gateways.md`). The verify-first answers (section 11) are in `docs/research/2026-10-26-gateways-verify-first.md`.

This changes LLM Chat 2.0 (design: [`2026-10-25-llmchat-design.md`](2026-10-25-llmchat-design.md), "the main spec") in three ways:
- It adds three gateway services (OpenCode, OpenRouter, Vercel AI Gateway) that speak the Chat Completions API.
- It drops the direct OpenAI provider.
- It replaces the Provider and Model rows in Settings with an OpenCode-style model picker. Every model is named `<service>/<model>`.

Mockups 09-14, drawn by the firmware in the simulator, are in [`docs/mockups/`](../../mockups/). The owner reviewed them and said "Yep, that looks all good".

Where this document and the main spec disagree, this document wins. The main spec's sections 5.1-5.4, 6, 8 and 11 get updated to match as part of the build (section 12).

Decisions are tagged as in the main spec. **Owner:** the owner decided it. **Call:** the author chose it, and the owner can still overrule it.

---

## 1. Why

The owner never meant OpenAI's own API. **Owner:** "I never actually meant to use the OpenAI API in particular. I have Opencode, Openrouter, Vercel keys." The models the owner wants to use are DeepSeek V4.1 Flash (`deepseek-v4.1-flash-1017`), MiniMax M3.1 Flash and Gemini 3.8 Flash. All three are on OpenRouter and Vercel, and OpenCode has a DeepSeek V4.1 Flash.

Settings has one Provider row with two choices and one model list per provider. Adding three services would mean three more key rows, three more model lists and a five-way provider choice. **Owner:** "can we just use an opencode style model picker like `<provider>/<model>`".

## 2. Goals, non-goals, anti-goals

**Goals**
1. Chat with any chat model on OpenCode, OpenRouter or Vercel, and keep Claude through Anthropic's own API. **Owner.**
2. Pick a model from one list, named `<service>/<model>`, with your recent models first and type-to-filter. **Owner:** the picker idea; **Owner:** agreed to the proposal (recent first, filter, lists from the services, opened with F4).
3. Switching models mid-chat works: the next message goes to the new model with the conversation so far.
4. Settings holds one key per service. **Owner:** agreed to the proposal.

**Non-goals (this version)**
- OpenAI's own API. **Owner:** agreed to drop it. GPT models are reachable through OpenRouter and Vercel.
- On OpenCode, the models it serves only through other APIs (Claude, GPT, Gemini and most Qwen models). Only its Chat Completions models are listed (section 8.2). **Call.**
- OpenCode Go, OpenCode's subscription endpoints. Their terms ask for coding-agent traffic, so a chat app is a grey area. **Call.**
- Prices, context sizes or any other model details in the picker. The lists keep only ids.
- Prompt caching for Claude models reached through a gateway (section 13).
- Tool use, images, local servers (Ollama), as in the main spec.

**Anti-goals**: it fails even if it works when...
- A key goes anywhere but its own service. A key is sent only to its own service's host (or to the loopback test server, section 9.3).
- Getting a model list makes the app hang, run out of memory, or stop responding to keys. The lists from OpenRouter and Vercel are 540-790 KB, about a sixth of the Lua heap, so they must never be held or decoded whole (section 8.3).
- Typing in the picker lags behind the keys.
- An old chat stops opening, or loses its Claude history, after the update.

## 3. Facts this rests on

Measured or read on 2026-10-26. The research notes, with a source for every fact, are in [`docs/research/gateway-api-facts.md`](../../research/gateway-api-facts.md), and the raw probe replies (ids removed) are in `docs/research/gateway-probes/`. The spend is logged in `docs/research/api-spend.md`.

- **TLS:** `openrouter.ai` and `opencode.ai` chain to GTS Root R4; `ai-gateway.vercel.sh` chains to ISRG Root X1. Both roots are in the firmware's CA bundle (`picodeck/src/drivers/ca_bundle.c`).
- **Chat Completions (CC) on all three:** `POST` with `Authorization: Bearer <key>`, `stream: true` and `stream_options: {include_usage: true}`. The SSE stream is `data: {json}` lines ending with `data: [DONE]`. No comment lines were seen, but OpenRouter documents `: OPENROUTER PROCESSING` keep-alives, which `src/sse.lua` already ignores.
- **Where the reasoning goes:**
  - Vercel and OpenRouter put the model's reasoning in `delta.reasoning` and `delta.reasoning_details`.
  - OpenCode puts it in `delta.reasoning_content`.
  - Gemini 3.8 Flash on Vercel sent only `reasoning_details`, with no plain `reasoning` text.
  - No `<think>` tags appeared in `content`.
- **Usage** arrives in the last data chunk:
  - On Vercel that chunk also carries a non-empty `choices`.
  - On OpenCode its `choices` is empty.
- **Requesting effort:**
  - Vercel accepted `reasoning: {effort: "low"}` for DeepSeek, MiniMax and Gemini.
  - OpenCode accepted `reasoning_effort: "low"` for DeepSeek.
  - OpenRouter documents `reasoning: {effort}`. It wasn't probed, as the owner's key has expired.
- **Errors:**
  - All three send `{"error": {"message", ...}}`.
  - OpenCode's 401 says `"type": "server_error"`, so decide by HTTP status, never by `error.type`.
  - OpenRouter: 402 means out of credit, and 403 covers moderation and budget limits as well as keys. A mid-stream error is a chunk with a top-level `error` and `finish_reason: "error"`, on an HTTP 200 stream.
- **Model lists:**
  - None of the three needs a key to read.
  - OpenRouter, `/api/v1/models`: 791 KB, 467 models; it takes `?output_modalities=text`.
  - Vercel, `/v1/models`: 544 KB, 480 entries; only `type: "language"` ones are chat models.
  - OpenCode, `/inference/v1/models`: 7 KB, 85 ids, with no details.
  - In both big lists, each model has exactly one `"id"` key and no nested object has one.
- **Id styles differ by service.**
  - OpenRouter and Vercel use `vendor/model`, with dotted versions (`anthropic/claude-opus-5.5`, `google/gemini-3.8-flash`).
  - OpenCode and Anthropic use bare ids (`deepseek-v4.1-flash`, `claude-opus-5-5`).
- **The owner's keys:** Anthropic, OpenCode, OpenRouter (expired: 401 "API key expired."), Vercel.

## 4. Model ids and services

A model id is `<service>/<the service's own model id>`. Everything after the first `/` is sent to the service unchanged:
- `anthropic/claude-opus-5-5`
- `opencode/deepseek-v4.1-flash`
- `openrouter/deepseek/deepseek-v4.1-flash-1017`
- `vercel/google/gemini-3.8-flash`

| Service | Label | Colour | Host | Chat path | Effort field | Key line |
|---|---|---|---|---|---|---|
| `anthropic` | Anthropic | `rgb(217,119,87)` | `api.anthropic.com` | `/v1/messages` (the existing Claude provider) | `output_config.effort` | `anthropic=` (`claude=` is read too) |
| `opencode` | OpenCode | `rgb(240,196,70)` | `opencode.ai` | `/inference/openai/v1/chat/completions` | `reasoning_effort` | `opencode=` |
| `openrouter` | OpenRouter | `rgb(120,140,255)` | `openrouter.ai` | `/api/v1/chat/completions` | `reasoning: {effort}` | `openrouter=` |
| `vercel` | Vercel | `rgb(215,215,215)` | `ai-gateway.vercel.sh` | `/v1/chat/completions` | `reasoning: {effort}` | `vercel=` |

- **Call:** the colours (mockups 09-13). Old chats' OpenAI replies keep OpenAI's green `rgb(16,163,127)`.
- A Claude model reached through a gateway (`openrouter/anthropic/claude-opus-5.5`) is just another CC model to the app. Only `anthropic/` uses Anthropic's own API, with its thinking blocks, refusal fallbacks and prompt caching (main spec 6.2, unchanged).
- **Call:** the default model, for a fresh install and for prefs that name none, is `anthropic/claude-opus-5-5`, as in the main spec.

## 5. Screens and keys

### 5.1 The model picker (mockups 09-11)
F4 on the chat screen opens it, at any time, including while a reply arrives; a pick applies from the next message.

**Layout.**
- Header "Model".
- A one-line filter field across the top, always focused, with the dim hint "Type to filter, or type a whole id" while it is empty.
- The list below it, in 6x8 with 13 px rows, scrolling, with a 2 px scroll bar.
- The footer: the keys on the left, and on the right "N models" or, while filtering, "N match".
- Two kinds of rows:
  - **Group rows:** a name in the title colour, a rule, and at the right the group's size and, for a downloaded list, its age ("today", "3d"). They can't be selected.
  - **Model rows:** a 4 px dot in the service's colour, the `service/` part dim, the rest bright. The current model has "in use" at the right. The selected row is on `rgb(40,70,130)`.

**Groups, in order:**
1. **Recent:** the last 8 models you sent with or picked, newest first. **Call:** 8.
2. **Anthropic:** the built-in list from `src/providers/claude.lua` (Opus 5.5, Sonnet 5.5, Haiku 5.5, Fable 5.1). Mockup 09 shows only the first three; the list has all four.
3. **OpenCode**, **OpenRouter**, **Vercel:** each service's downloaded list (section 8).
   - A group whose service has no key shows the dim line "No key yet: add one in Settings (F5)".
   - A group whose list is downloading shows "Getting the model list...".
   - A group whose download failed shows the reason, for example "Couldn't get the list: No WiFi. F2 tries again."

The same model may appear in Recent and in its own group, and the same upstream model under several services. Each row is a different way to reach it.

**Filtering (mockup 10):**
- Case-insensitive.
- The filter is split into words at spaces. A model matches when every word appears somewhere in its full id. **Call:** words, so `ds flash` or `vercel gem` narrow quickly.
- Groups keep their order, and empty groups are hidden while filtering.
- In each row, the first word's match is drawn in `rgb(255,210,90)`.
- **A whole id:** when the trimmed filter has the form `<known service>/<rest>`, is a valid id (`^%w[%w%._:/~%-]*$`, at most 120 characters), and isn't exactly a listed id, a first row "Use `<id>`" appears. Enter on it picks that id as it is. This replaces the old "Custom..." model.

**Keys:**

| Key | Action |
|---|---|
| typing, Left/Right, Backspace, Del | edit the filter |
| Up / Down | move between model rows (group and message rows are skipped); hold to repeat |
| Shift+Up / Shift+Down | a page |
| Enter | pick the selected model, and go back to the chat |
| Esc | clear the filter; when it's already empty, go back without changing anything |
| F2 | download every keyed service's list again |

On opening, the selection is on the current model's row in Recent.

### 5.2 Chat screen (mockups 12-13)
Changes to main spec 5.1:
- **New chat intro:** "Ask anything", then the current model's full id with its service dot, then the key caps F1 "Recent chats", F4 "Model" and F5 "Settings".
- **Footer, right side:** the part of the id after its last `/` (`gemini-3.8-flash`), cut with ".." if it doesn't fit beside the keys. **Call:** the whole id would not fit.
- **Reply bars** take the colour of the service that wrote the reply.
- **There is one current model** (`prefs.model`). It isn't remembered per chat. **Call:** this follows from "new chats start on the last model you picked" and keeps one rule for every case.
- **Model switch line:**
  - When you send in a chat whose last reply came from a different model than the current one, a note "now `<id>`" is added before your message.
  - This covers both picking a new model mid-chat and reopening an old chat.
  - It is drawn dim and centred between two thin rules (mockup 13). Like every note, it is never sent.
- **No key** for the current model's service: the note "Add your `<Label>` key in Settings (F5), or pick another model (F4)."
- F4 is added to the chat keys table: "pick a model".

### 5.3 Recent chats and the program error screen
- **Chats tab** (main spec 5.2): the second line shows the service label ("Vercel  4 messages"), and the dot takes the service colour. Old chats show "Anthropic" for `claude`, and "OpenAI" for `openai`.
- **Program error screen** (main spec 5.3): the button reads "Ask the model to fix". **Call:** a name like `deepseek-v4.1-flash-1017` doesn't fit a button. The hint line names the short model: "`gemini-3.8-flash` can see the error and the code and send back a fixed version."
  - The fix goes to the current model.

### 5.4 Settings (mockup 14)
Two dim section labels, each followed by a thin rule, and these rows:

| Section | Row | Widget |
|---|---|---|
| API keys | Anthropic | key field, masked |
| | OpenCode | key field, masked |
| | OpenRouter | key field, masked |
| | Vercel | key field, masked |
| Replies | Thinking | `W.Select`: Low (default) / Medium / High |
| | Reply font | `W.Select`: Sans / System (6x8) |
| | Instructions | `W.TextArea`, 3 rows |

- Section labels can't be focused; Up and Down skip them.
- Key fields behave as in the main spec. Enter edits in clear text, and an empty key removes it. The mask keeps a known prefix (`sk-ant-`, `sk-or-v1-`, `sk-`), then stars and the last 4 characters.
- The dim note under the rows stays: "Keys are long to type: you can also put them in keys.txt in the app's data folder."
- The Provider and Model rows are gone.

## 6. The Chat Completions provider

One module serves the three gateways from a table of their differences (section 4). It has the same shape as the main spec's providers (6.1): `request`, `parser`, `titleRequest`, `titleText`, `describeError`.

### 6.1 Request
```json
{
  "model": "<the id after the service part>",
  "stream": true,
  "stream_options": {"include_usage": true},
  "messages": [
    {"role": "system", "content": "<main spec section 10>"},
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "<the service's effort field>": "low | medium | high"
}
```
- **Effort:** OpenRouter and Vercel send `"reasoning": {"effort": e}`; OpenCode sends `"reasoning_effort": e`, where `e` is the Thinking setting, lower case.
- **Call: no `max_tokens`.** Each service then uses the model's own limit. Section 11 checks that this doesn't cut a long program short. The main spec's 32000 could be rejected by a model whose limit is lower.
- **History:** every reply goes as plain text, whatever model or service wrote it. Notes are skipped, and so are replies with only whitespace. Claude's `raw` blocks go only to `anthropic/` (main spec 6.2).
- **Headers:** `Authorization: Bearer <key>`, `Content-Type: application/json`, `Accept: text/event-stream`.

### 6.2 Stream
Each `data:` line is one JSON chunk. `[DONE]` ends the stream.
- `choices[1].delta.content`: visible text.
- A non-empty `delta.reasoning`, `delta.reasoning_content` or `delta.reasoning_details`: `handlers.thinking()`. The reasoning text isn't shown or kept.
- `choices[1].finish_reason`:
  - `stop`: end.
  - `length`: the main spec's "Reply cut off at the length limit."
  - `content_filter`: the refusal note, "`<short model>` declined to answer this."
  - `error`: an error.
  - Anything else: end.
- A top-level `error` object (OpenRouter's mid-stream error): `handlers.error(error.message)`.
- `usage`, in whichever chunk has it, goes into `done`'s info.
- `done` is called at `[DONE]`. A stream that closes after a `finish_reason` but without `[DONE]` also counts as done. **Call:** the finish reason already says the reply is whole.
- Unknown fields and chunks are ignored, as in the other parsers.

### 6.3 Errors
Main spec 6.4 applies, with these lines for the gateways. The status decides; the body's `error.message` goes under the friendly line.
- **401:** "`<Label>` rejected the API key. Check Settings." This covers OpenRouter's "API key expired."
- **402:** "Your `<Label>` account is out of credit."
- **403:** "`<Label>` refused this request." OpenRouter uses 403 for moderation and budget limits; the message says which.
- **429:** "Rate limited; try again in a moment." With the `Retry-After` seconds when the header is present.
- **5xx:** "`<Label>` is busy; try again."
- **Anything else:** "`<Label>`: HTTP `<status>`." An unknown model id typed by hand lands here, with the service's message under it.

### 6.4 Titles
Main spec 8.2's title request, for a gateway chat:
- A non-streaming CC request to the chat's own model. **Owner:** agreed (these are cheap models).
  - The same prompt as the main spec.
  - `max_tokens: 300` and effort `low`. **Call:** room for a reasoning model's thinking before the few title words.
- The title is `choices[1].message.content`.
- When that is empty or the request fails, the chat keeps its cut first message, as in the main spec.
- `anthropic/` chats keep using Haiku 5.5.

## 7. The Anthropic service

`src/providers/claude.lua` stays as it is, apart from names:
- Its models' full ids get the `anthropic/` prefix.
- Its key is read from `anthropic=` or `claude=` and written as `anthropic=`.
- Its test base override becomes `anthropic_base`.
- Old chat items with `provider: "claude"` count as `anthropic`. Their raw blocks still go back to Claude, so an old Claude chat continues with its thinking history intact.

The OpenAI provider (`src/providers/openai.lua`), its fixtures and tests, and `openai_base` are removed. Old chats with OpenAI replies still open and can go on: those replies go to any model as plain text.

## 8. Model lists

### 8.1 Where they come from

| Service | Request | Keep |
|---|---|---|
| Anthropic | none: built in | all |
| OpenCode | `GET https://opencode.ai/inference/v1/models` | ids starting `deepseek-`, `glm-`, `kimi-`, `minimax-`, `mistral-`, and `qwen3.8-max`; minus ids ending `-free`, and `big-pickle` |
| OpenRouter | `GET https://openrouter.ai/api/v1/models?output_modalities=text` | all, minus ids ending `:batch` |
| Vercel | `GET https://ai-gateway.vercel.sh/v1/models` | `type` is `language`, minus ids ending `-batch` |

- **Why OpenCode is filtered:** its chat endpoint serves only some families, and its list doesn't say which. The keep rule is OpenCode's documented Chat Completions families as of 2026-10-26. A model the rule misses can still be typed whole. **Call.**
- **Free models:** OpenCode's free models refuse every client but OpenCode itself, so they are left out.
- **Call:** batch variants are dropped as clutter. They are meant for batch jobs, not chat.
- The request carries the service's key when there is one. **Call:** it's the service's own host, and the list may then reflect the account.

### 8.2 When
- **Opening the picker** starts a download for every service that has a key but no saved list, one at a time.
- **F2** downloads every keyed service's list again. **Call:** there's no automatic refresh; the age on the group row says when it's stale.
- **Closing the picker** cancels a download in progress. The saved list is replaced only when a new one is complete (the main spec's safe save).
- A download while a reply is arriving is fine if the device copes with two connections at once (section 11). Otherwise downloads wait until the reply ends.

### 8.3 Reading a big list without holding it
The body is never kept whole or decoded whole.
- Each arriving chunk is scanned for `"id":"<value>"` pairs. For Vercel, the scan also reads the `"type":"<value>"` of the same entry.
- An unfinished pair at the end of a chunk is carried over to the next one.
- Only the kept ids are held. That is about 800 ids of about 30 bytes each across all three lists.
- **Why a scan is safe here:** JSON escapes every `"` inside a string. So `"id":"` outside a key position would read `\"id\":\"`, which the scan must skip. Each list has exactly one `"id"` per model (section 3).
- **Left to the builder:** whether to scan, or to use a small streaming tokenizer. The requirement is memory bounded by the kept ids plus one chunk.

### 8.4 On the card
- `models/<service>.txt`, one id per line without the service part.
- The first line is `# fetched <epoch>`.
- The files are read when the picker opens.

## 9. Storage and moving old data over

### 9.1 `prefs.json`
- `model`: the current model's full id.
- `recent`: up to 8 full ids, newest first. A model goes to the top when you pick it and when you send with it.
- **Removed:** `provider` and `models`.
- **Moving an old `prefs.json` over, on load:** when `model` is missing and `models.claude` is set, `model` becomes `anthropic/<models.claude>`. Otherwise it is the default. Then `provider`, `models`, `claude_base` and `openai_base` are dropped. **Call:** a saved OpenAI choice falls back to the default, as there's no OpenAI any more.

### 9.2 `keys.txt`
- The names are `anthropic`, `opencode`, `openrouter` and `vercel`.
- `claude=` is read as `anthropic=`. **Call:** keys files already on cards, the owner's included, keep working.
- An `openai=` line is ignored.
- When Settings saves a key, the file is written with the four current names. An `openai=` line is dropped then.

### 9.3 Test overrides
- The hidden test overrides become `anthropic_base`, `opencode_base`, `openrouter_base` and `vercel_base`, still loopback only (main spec 5.4).
- Each one replaces both its service's chat host and its model-list host.

### 9.4 Chats
- **Assistant items:** `provider` is the service id and `model` is the full id.
- **Old items:**
  - A `model` with no service part is shown as `anthropic/<model>` for `claude` items, and as it is for `openai` items.
  - When an old item is compared with the current model (for the switch line), its model is first written as a full id.
- **The index:** `chats/index.json` keeps `provider` and `model` as the last reply's.
- **The switch note:** `{"role": "note", "kind": "model", "text": "now <id>"}`.

### 9.5 Importing from the old app (main spec 8.4)
Only a provider-2 (Claude) key is imported, as `anthropic=`. A provider-1 key is an OpenAI key and is ignored. **Call.**

## 10. Testing and spend

**Real API use.** The main spec's rules hold:
- The keys stay in `~/.config/llmchat/keys.txt` (mode 600), outside the repo.
- Only the line for the service being tested is read.
- Every request is logged in `docs/research/api-spend.md`.
- The total stays under about $2. About $0.0025 is spent so far.

**Recording:**
- `tools/record_stream.py` learns CC requests.
- **Vercel and OpenCode:** record text, reasoning, a `length` stop (a small `max_tokens`, recording only), a title reply and a 401.
- **OpenRouter:** its 401 is real (the expired key). Its other cases are hand-written from its docs (`.hand.sse`) until the owner renews the key:
  - text;
  - the mid-stream `error` chunk;
  - a keep-alive comment line.
- Expected cost: under $0.05.

**Host tests:**
- **CC parser:** every recorded and hand-written stream, split at every chunk boundary. Usage both with and without `choices`. `[DONE]` missing after a finish reason.
- **Request builder:** golden JSON per service, effort field included. A conversation with Claude replies (with `raw`) and old OpenAI replies sent to a gateway as plain text. Under lua32, integers encode without `.0`.
- **List scanner:**
  - Fixtures cut from the real lists (a few KB each), split at every chunk boundary.
  - An escaped `\"id\":\"` inside a description is ignored.
  - Each service's keep rules.
  - A large generated list keeps memory bounded.
- **Picker logic** (pure, no drawing):
  - Word filtering.
  - Group order and hiding.
  - The "Use `<id>`" row and id validation.
  - Recent ordering and its cap.
  - Selection skipping group rows.
- **Store:** moving old prefs over, the `claude=` alias, `openai=` ignored, list files with their age line, the switch-note rule.

**Simulator e2e:**
- The fake API learns CC streams, non-streaming title replies and the three `/models` endpoints.
- **Cases:**
  - F4 opens the picker. Typing filters it, Enter picks, and the footer shows the new model.
  - Sending after a switch adds the "now `<id>`" line.
  - A gateway reply streams.
  - A gateway 401 shows the right note.
  - Settings saves the four keys.
  - An old Claude chat (with `raw`) continues on `anthropic/`.

**Device checks**, added to `docs/device-checklist.md`:
- A real chat on each keyed service.
- Downloading each list: time, and the lowest free heap.
- Filtering about 800 ids.
- The switch line.

## 11. Verify first

The builder starts with these, because each could change the design:
1. **The big lists on the device.** Download and scan Vercel's and OpenRouter's lists on the PicoCalc. Both work without a key, so the expired OpenRouter key doesn't block this. Measure:
   - the time;
   - the lowest free heap;
   - whether the screen and keys stay responsive (the spinner moves, Esc works).

   **If it can't be made to work well,** rule a fallback (for example, a short built-in list per gateway, plus typed ids) and tell the owner.
2. **Filtering speed on the device** with all three lists loaded: one keystroke must redraw without a visible lag.
3. **No `max_tokens`:** a long program reply (about 300 lines) isn't cut short by a service's default limit, on each keyed service with the owner's models. If one is, send a `max_tokens` that service accepts.
4. **Effort on a model that doesn't reason:** each service either ignores it or rejects it. If one rejects it, rule how to tell such models apart.
5. **Two connections at once** on the device: a list download while a reply streams.

## 12. Left to the builder
- Module boundaries: one CC module with a service table, or one per service. Where the picker's pure logic lives. How the screens hand the picked model back.
- The list scanner's approach (8.3), within its memory requirement.
- Exact spacing and colours beyond the mockups and this document.
- Updating the main spec's sections 5.1-5.4, 6, 8 and 11, the README (keys, `keys.txt`, the picker) and `docs/device-checklist.md` to match. This happens as the last task, so the main spec stays the app's reference.
- Which recordings to make, within the budget.

## 13. Later
- Prompt caching for Claude models reached through a gateway. OpenRouter needs `cache_control` markers; Vercel needs `caching: "auto"`. Gateway chats on the owner's models cache by themselves.
- OpenCode's Claude, GPT and Gemini models, through their own APIs on OpenCode.
- Remembering a model per chat.
- Showing a model's price or context size in the picker.
- `<think>` tags in a reply's text, if a model ever sends them there.
