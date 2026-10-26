# Gateway services and the model picker: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LLM Chat talks to OpenCode, OpenRouter and Vercel AI Gateway as well as Anthropic. Every model is named `<service>/<model>` and chosen in an F4 picker, Settings holds one key per service, and the direct OpenAI provider is gone.

**Architecture:**
- A pure `src/services.lua` holds the service table and the id rules.
- One Chat Completions provider module (`src/providers/cc.lua`) is built once per gateway from that table. `src/providers/claude.lua` stays the `anthropic` service.
- The chat controller looks its provider up from the current model id.
- Model lists stream in over `Http.get`, and a chunk scanner keeps only the ids, never the body.
- The picker's logic is a pure module (`src/picker.lua`), drawn by a new screen.

**Tech Stack:**
- Lua 5.4 on the PicoDeck firmware (32-bit integers, floats; no `io`/`os`/`debug`).
- Host tests under `lua` and `build/lua32`; pytest e2e on PicoDeck's simulator.
- Python 3 for `tools/record_stream.py` and the probes.

**Spec:** `docs/superpowers/specs/2026-10-26-llmchat-gateways-design.md` ("§" below), which changes `docs/superpowers/specs/2026-10-25-llmchat-design.md` ("main §"). Where they disagree, the gateways spec wins. The mockups are `docs/mockups/09-*.png` to `14-*.png`. Facts and raw probe replies: `docs/research/gateway-api-facts.md` and `docs/research/gateway-probes/`.

**Before Task 1:** `chore/real-claude-fixtures` (the real Claude recordings and `docs/research/api-spend.md`) is merged into `main` (the owner's choice). The work goes on branch `feat/gateways` from that `main`.

## Global Constraints

**Services** (copy exactly; §4, §8.1)

| id | label | colour | base | chat path | list path | effort |
|---|---|---|---|---|---|---|
| `anthropic` | `Anthropic` | `{217,119,87}` | `https://api.anthropic.com` | `/v1/messages` | none (built in) | `output_config.effort` (existing) |
| `opencode` | `OpenCode` | `{240,196,70}` | `https://opencode.ai` | `/inference/openai/v1/chat/completions` | `/inference/v1/models` | `reasoning_effort` |
| `openrouter` | `OpenRouter` | `{120,140,255}` | `https://openrouter.ai` | `/api/v1/chat/completions` | `/api/v1/models?output_modalities=text` | `reasoning = {effort}` |
| `vercel` | `Vercel` | `{215,215,215}` | `https://ai-gateway.vercel.sh` | `/v1/chat/completions` | `/v1/models` | `reasoning = {effort}` |

- Order everywhere (picker groups, Settings rows, `keys.txt`): anthropic, opencode, openrouter, vercel.
- **Default model:** `anthropic/claude-opus-5-5`.
- **A valid full id:** `<known service>/<rest>`, with `rest` non-empty, the whole id matching `^%w[%w%._:/~%-]*$`, and at most 120 characters.
- **Old items:** provider `claude` means `anthropic`. OpenAI's bar colour stays `{16,163,127}`, and its label is `OpenAI`.

**Chat Completions requests**
- `stream: true`, `stream_options: {include_usage: true}`, the system prompt as the first `messages` entry.
- No `max_tokens` on chat requests, unless Task 1 rules otherwise. Title requests send `max_tokens: 300` and effort `low`.
- Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`, `Accept: text/event-stream` (the title request omits `Accept`).
- Decide errors by HTTP status, never by `error.type`.

**Prefs and files** (§9)
- `prefs.model` (full id) and `prefs.recent` (up to 8 full ids, newest first). `provider` and `models` are gone.
- `keys.txt` names: `anthropic`, `opencode`, `openrouter`, `vercel`. `claude=` is read as `anthropic=`, and `openai=` is ignored.
- Test overrides: `<service>_base`, accepted only as `http://127.0.0.1:<port>` or `http://localhost:<port>`.
- `models/<service>.txt`: first line `# fetched <epoch>`, then one id per line without the service part.

**Copy** (exact)
- No key: `Add your <Label> key in Settings (F5), or pick another model (F4).`
- The switch note: `now <full id>`.
- The filter field's hint: `Type to filter, or type a whole id`.
- Picker messages:
  - `No key yet: add one in Settings (F5)`
  - `Getting the model list...`
  - `Couldn't get the list: <why>. F2 tries again.`
- Gateway error lines (§6.3):
  - `<Label> rejected the API key. Check Settings.`
  - `Your <Label> account is out of credit.`
  - `<Label> refused this request.`
  - `Rate limited; try again in a moment.`
  - `<Label> is busy; try again.`
  - `<Label>: HTTP <status>.`
- The program error button: `Ask the model to fix`.

**Colours, beyond the main plan's**
- Filter match `rgb(255,210,90)`.
- Group-row name: the theme's `title` colour; rule `rgb(85,85,85)`.

**Code rules** (as in the main plan)
- Tests pass under `lua` and `build/lua32`.
- Never `json.encode` an empty table: `recent` is left out of `prefs.json` when it is empty.
- HTTP callbacks only append and set flags.
- UI chrome is drawn in `FONT_6X8`.
- No key uses Tab.
- Filter matching uses plain `string.find(s, word, 1, true)`, never patterns.

**Keys, money and the device**
- Keys live only in `~/.config/llmchat/keys.txt` (mode 600; the laptop file names the Anthropic key `claude=`) and on the device. Read only the line for the service in use. Never commit, log or print a key.
- Log every real request in `docs/research/api-spend.md`. The project total stays under about $2; about $0.0025 is spent so far.
- Before driving the PicoCalc, check it is idle and ask the owner. Use `/apps/.dev/<name>`, never `/apps/llmchat`. Remove what you added afterwards.

**Commits:** conventional style (`feat(picker): ...`, `test: ...`, `docs: ...`).

## Review Focus

Inputs the spec implies but no task would otherwise test:
1. **Filter text with Lua pattern characters** (`gpt-5.6`, `(`, `%`, `[`). It matches literally and never raises. *Test in Task 9.*
2. **A typed id that is almost valid**: `openrouter/` alone, `foo/bar` (an unknown service), upper case or spaces, a trailing `/`, over 120 characters. None gets a "Use" row, and nothing raises. *Test in Task 9.*
3. **A list download that fails or returns junk**: HTTP 503, an HTML page, a body cut short. The group shows `Couldn't get the list: <why>. F2 tries again.` The saved list stays as it was, and nothing is written. *Test in Task 8.*
4. **The current model's key is removed in Settings after it was picked.** Sending shows the no-key note, and the picker still lists the model in Recent. *Test in Task 6.*
5. **A gateway reply with reasoning but no text** (`finish_reason: stop`, empty `content`). No empty assistant item is stored, and the next message sends normally. *Test in Task 6.*

---

### Task 1: Verify-first probes (§11)

Answers the spec's five open questions before code depends on them.

**Files:**
- Create: `tools/probes/cc.py`, a laptop probe for questions 3 and 4.
- Create: `tools/probes/lists/app.json` and `tools/probes/lists/main.lua`, a device probe for questions 1, 2 and 5.
- Create: `docs/research/2026-10-26-gateways-verify-first.md`.
- Modify: `docs/research/api-spend.md`.

**Interfaces:**
- Produces, as decision lines in the findings doc that Tasks 4, 6 and 8 read:
  - `LISTS_OK = yes|no`
  - `FILTER_MS = <n>`
  - `MAX_TOKENS = omit | <service>: <n>`
  - `EFFORT_REJECTED = none | <service> on <model>: <rule>`
  - `TWO_CONNECTIONS = yes|no`

- [ ] **Step 1: The laptop probe.** `tools/probes/cc.py <service> <model> [--long] [--effort low|none]` makes one streaming CC request and prints the finish reason, the output tokens, the cost from `usage.cost`, and the HTTP status. It may start from the session probe whose logic is described in `docs/research/gateway-api-facts.md` ("Measured 2026-10-26").
  - The key comes from the keys file (mode check); only that service's line is read.
  - Ids in the output are scrubbed.
  - `--long` asks: "Write a complete Lua program of about 300 lines: a Snake game for a 320x320 screen."
- [ ] **Step 2: Question 3 (no `max_tokens`).**
  - Run `--long` with no `max_tokens` on `vercel deepseek/deepseek-v4.1-flash-1017`, `vercel minimax/minimax-m3.1-flash`, `vercel google/gemini-3.8-flash` and `opencode deepseek-v4.1-flash`.
  - **Pass:** `finish_reason` is `stop` and the output is over 2,000 tokens.
  - **Fail:** record the length where it stopped. The ruling is `MAX_TOKENS = <service>: <the model's documented max output>` for that service.
  - Log the spend: expected under $0.03.
- [ ] **Step 3: Question 4 (effort on a model that doesn't reason).**
  - Pick one Vercel model and one OpenCode model whose list entry shows no reasoning support. For Vercel, the entry has no `reasoning_options`; for OpenCode, use `mistral-*` if one is listed.
  - Send effort `low` to each.
  - **Pass:** HTTP 200. Otherwise record the error, and rule how to tell such models apart. For example, a 400 whose message names reasoning could be retried once without the effort field.
- [ ] **Step 4: The device probe app.**
  - **Setup:** id `dev.llmchat.probe.lists`, requirements `["http"]`.
  - **Download:** it GETs `https://ai-gateway.vercel.sh/v1/models`, then `https://openrouter.ai/api/v1/models?output_modalities=text`, with no key.
    - It uses the main plan's callback rule: callbacks append the chunks.
    - The main loop scans each chunk for `"id":"..."`, carrying the tail over (a probe-local scanner).
  - **Every frame:** it draws a spinner and the byte count, polls Esc, and keeps the lowest `sys.getMemInfo().psram_free`.
  - **Two at once:** a second case starts both GETs together, to answer question 5.
  - **Filter timing:** it then filters the ids it collected 20 times each for `f`, `flash` and `ds flash`, the way §5.1 describes, and records the average ms per keystroke.
  - **Results:** written to `/data/dev.llmchat.probe.lists/results.txt`, one line each: `<case> bytes=<n> ids=<n> ms=<n> lowfree=<n> fps=<n>`, `filter <q> <ms>`, and `two <ok|failed: err>`.
- [ ] **Step 5: Run it in the simulator** with `tools/probes/drive.py`, extended with a `lists` case.
  - **Expected:** both downloads finish, with about 318 language ids from Vercel (the probe counts all ids; that's fine) and over 400 from OpenRouter.
- [ ] **Step 6: Run it on the device.**
  - Check the device is idle and ask the owner first.
  - Push to `/apps/.dev/listsprobe` (`push_app`, `hidden="dev"`), launch it, and wait for `done` in `results.txt`.
  - Copy `results.txt` back, then remove `/apps/.dev/listsprobe` and `/data/dev.llmchat.probe.lists`.
- [ ] **Step 7: Write the findings,** one section per question with its numbers, then the decision lines.
  - `LISTS_OK = no` when either list takes over 60 s, leaves under 1 MB free at its low point, or drops the frame rate under 5 fps.
  - If `LISTS_OK = no`:
    - Rule the fallback: Task 8 ships a built-in short list for that service instead of downloading, built from the owner's three models and that service's other current flagship ids in `docs/research/gateway-api-facts.md`.
    - Write **TELL THE OWNER** at the top of the doc, and tell them before Task 8.
  - `FILTER_MS` over 50 means Task 9 filters incrementally: narrow the previous result when the filter only grew.
- [ ] **Step 8: Commit.** `git add tools/probes docs/research && git commit -m "research: gateway verify-first probes (lists, filter, max_tokens, effort, two connections)"`

### Task 2: The service table and id rules

**Files:**
- Create: `src/services.lua`, `tests/test_services.lua`

**Interfaces:**
- Produces (`local Services = require("src.services")`):
  - `Services.ORDER`: `{ "anthropic", "opencode", "openrouter", "vercel" }`.
  - `Services.BY_ID[id]`: `{ id, label, color = {r,g,b}, base, chatPath, listPath (nil for anthropic), effort = "output_config"|"reasoning"|"reasoning_effort" }`.
  - `Services.DEFAULT_MODEL`: `"anthropic/claude-opus-5-5"`.
  - `Services.split(full) -> serviceId, rest`, or `nil` for anything that isn't a valid full id.
  - `Services.valid(full) -> boolean`.
  - `Services.short(full) -> string`: the text after the last `/`.
  - `Services.full(provider, model) -> string|nil`: an item's model as a full id.
    - A model that is already a valid full id comes back as it is.
    - With provider `claude`/`anthropic`, it becomes `anthropic/<model>`.
    - With provider `openai`, it becomes `openai/<model>`.
    - Otherwise it becomes `<provider>/<model>`.
    - With no model, it returns `nil`.
  - `Services.of(provider) -> serviceId`: `claude` becomes `anthropic`; everything else is unchanged.
  - `Services.label(provider)`: the label, `OpenAI` for `openai`, else the provider string itself.
  - `Services.color(provider) -> {r,g,b}`: OpenAI's green for `openai`, dim `{130,130,130}` for unknown providers.

- [ ] **Step 1: Write the failing tests** in `tests/test_services.lua`:
  - `table_matches_spec`: every row of the Global Constraints table, field by field.
  - `split_and_valid`:
    - `split("openrouter/deepseek/deepseek-v4.1-flash-1017")` gives `"openrouter", "deepseek/deepseek-v4.1-flash-1017"`.
    - `split("opencode/deepseek-v4.1-flash")` gives `"opencode", "deepseek-v4.1-flash"`.
    - `split("openrouter/~deepseek/deepseek-flash-latest")` splits.
    - `nil` for `"openrouter/"`, `"foo/bar"`, `"anthropic"`, `"vercel/a b"`, `"Vercel/x"`, `"vercel/x/"`, and a 121-character id.
  - `short`: `"gemini-3.8-flash"` from `vercel/google/gemini-3.8-flash`; `"claude-opus-5-5"` from `anthropic/claude-opus-5-5`.
  - `full_old_items`:
    - `full("claude", "claude-opus-5-5")` is `"anthropic/claude-opus-5-5"`.
    - `full("openai", "gpt-6-luna")` is `"openai/gpt-6-luna"`.
    - `full("vercel", "vercel/google/gemini-3.8-flash")` is unchanged.
    - `full("claude", nil)` is `nil`.
  - `labels_and_colors`: `of`, `label` and `color` for the four services, `claude`, `openai` and `"zzz"`.
- [ ] **Step 2: Run, expect failures.** `lua tests/run.lua tests/test_services.lua` (module not found).
- [ ] **Step 3: Implement `src/services.lua`.** It has no requires.
- [ ] **Step 4: Run, expect a pass:** `make test`.
- [ ] **Step 5: Commit.** `feat(services): the service table and model id rules`

### Task 3: Store: prefs, keys, test bases, model list files

**Files:**
- Modify: `src/store.lua`, `tests/test_store.lua`

**Interfaces:**
- Consumes: `Services` (Task 2).
- Produces:
  - **Prefs:**
    - `store:prefs()` has `model` (full id) and `recent` (list, possibly empty). An old `prefs.json` is moved over on load, as §9.1 says.
    - An invalid `model` becomes the default; invalid or duplicate `recent` entries are dropped, and the list is capped at 8.
    - `Store.RECENT_MAX = 8`.
    - `store:pushRecent(full)` moves `full` to the front and caps the list. It doesn't save.
  - **Keys:**
    - `store:keys()` is keyed by service id. `claude=` is read as `anthropic`, but an `anthropic=` line wins over it. `openai=` is ignored.
    - `store:setKey(serviceId, key)` writes a header line, then `anthropic=`, `opencode=`, `openrouter=`, `vercel=` lines.
  - **Bases:** `store:base(serviceId)` returns `prefs["<serviceId>_base"]` when it is loopback, else `nil`.
  - **Model lists:**
    - `store:modelList(serviceId) -> { fetched = <epoch|nil>, ids = {...} }`, or `nil` when there is no file.
    - `store:saveModelList(serviceId, ids, epoch) -> true | nil, err`, a safe save through `writeText`.
  - **Old-app import:** `store:importOld(config)` imports provider `2` as `anthropic`. A provider `1` key isn't imported, but the old config keys are still cleared.

- [ ] **Step 1: Write the failing tests.** Change the existing store tests that use `claude`/`openai` keys or `prefs.provider`/`prefs.models` to the new names, then add:
  - `prefs_defaults`: `model == "anthropic/claude-opus-5-5"`, `recent` empty, and `prefs.json` saved with no `recent` key.
  - `prefs_migrates_old`:
    - `{provider="claude", models={claude="claude-sonnet-5-5", openai="gpt-6-luna"}, claude_base="http://127.0.0.1:9"}` gives `model == "anthropic/claude-sonnet-5-5"`, `anthropic_base` kept, and no `provider`/`models`/`claude_base`/`openai_base` after a save.
    - `{provider="openai", models={openai="gpt-6-luna"}}` gives the default.
  - `prefs_tampered`: `model = 5`, `model = "foo/bar"`, `recent = {"x", 3, "vercel/a", "vercel/a"}`. The result is the default model and `recent == {"vercel/a"}`.
  - `push_recent`: order, de-duplication, the cap at 8.
  - `keys_alias`:
    - A file with `claude=A` gives `keys().anthropic == "A"`.
    - `claude=A` plus `anthropic=B` gives `"B"`.
    - `openai=C` is ignored.
    - `setKey("vercel", "V")` writes exactly the four lines in order.
  - `base_per_service`: `vercel_base` loopback is accepted; `https://evil.example` is refused.
  - `model_list_roundtrip`: save `{"a","b"}` at epoch 1792000000, then read it back. A missing file gives `nil`. A file with no `# fetched` line gives `fetched == nil` with the ids kept.
  - `import_old`: provider `2` writes `anthropic=`; provider `1` imports nothing but clears the old keys.
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement.** `models/` is a new folder: create it the way `chats/` is created.
- [ ] **Step 4: Run, expect a pass:** `make test`.
- [ ] **Step 5: Commit.** `feat(store): one current model, recent models, a key per service, model list files`

### Task 4: The recorder learns Chat Completions; gateway fixtures

**Files:**
- Modify: `tools/record_stream.py`, `tests/tools/test_record_stream.py`, `docs/research/api-spend.md`
- Create:
  - `tests/fixtures/vercel-text.sse`, `vercel-reasoning.sse`, `vercel-length.sse`, `vercel-title.json`, `vercel-401.json`
  - `tests/fixtures/opencode-text.sse`, `opencode-reasoning.sse`, `opencode-title.json`, `opencode-401.json`
  - `tests/fixtures/openrouter-401.json`, `openrouter-text.hand.sse`, `openrouter-error.hand.sse`

**Interfaces:**
- Consumes: `MAX_TOKENS` from Task 1's findings.
- Produces:
  - **Usage:** `tools/record_stream.py <anthropic|opencode|openrouter|vercel> <case> [--dry-run]`.
    - Gateway cases: `text`, `reasoning`, `length`, `title`, `401`.
    - `anthropic` keeps the Claude cases. It reads the laptop's `claude=` line; `claude` is accepted as a service name too, so old commands still work.
  - **Fixture names:** `<service>-<case>.sse`, or `.json` for `title` and `401`. The JSON ones start with a `#status N` line, like the Claude ones.

- [ ] **Step 1: Write the failing tool tests** (no network, no keys):
  - `cc_request_shape`: for each gateway service and case, the URL, headers (key masked), and the body fields of §6.1. The `length` case adds `max_tokens: 40`; the `title` case is non-streaming with `max_tokens: 300`.
  - `cc_spend_uses_usage_cost`: a usage chunk with `cost: 0.000116` logs `$0.0001`.
  - `scrub_cc_ids`: `chatcmpl-...`, `gen-...` and `"id":"..."` are scrubbed; `generationId` values too.
- [ ] **Step 2: Run, expect failures.** `make test-tools`.
- [ ] **Step 3: Implement.**
  - **Models:** `vercel` records on `deepseek/deepseek-v4.1-flash-1017`; `opencode` on `deepseek-v4.1-flash`.
  - **Bad key:** the `401` case sends `bad-key-for-recording`. For `openrouter`, the real expired key also gives a real 401, so either works.
- [ ] **Step 4: Run, expect a pass:** `make test-tools`.
- [ ] **Step 5: Record.** Run every Vercel and OpenCode case, and `openrouter 401`.
  - Check every fixture: no key, and the ids scrubbed.
  - Log the spend: expected under $0.02.
- [ ] **Step 6: Hand-write the OpenRouter streams** from OpenRouter's documented shapes (`docs/research/gateway-api-facts.md`, OpenRouter section):
  - `openrouter-text.hand.sse` contains a `: OPENROUTER PROCESSING` comment line mid-stream, `delta.reasoning` chunks, text chunks, `finish_reason: "stop"`, a usage chunk and `[DONE]`.
  - `openrouter-error.hand.sse` has text chunks, then one chunk with a top-level `error: {code: "server_error", message: "Provider disconnected unexpectedly"}` and `finish_reason: "error"`, and no `[DONE]`.
- [ ] **Step 7: Commit.** `test: Chat Completions recordings for Vercel and OpenCode, OpenRouter by hand`

### Task 5: The Chat Completions provider

**Files:**
- Create: `src/providers/cc.lua`, `tests/test_cc.lua`
- Modify: `src/providers/claude.lua`, `tests/test_claude.lua`

**Interfaces:**
- Consumes: `Services.BY_ID` (Task 2); the fixtures (Task 4); `MAX_TOKENS` and `EFFORT_REJECTED` (Task 1).
- Produces, the same shape for both modules (main §6.1 plus what's new here):
  - **The module:** `CC.new(service) -> P`, with `P.id`, `P.label` and `P.BASE = service.base`.
  - **The request:** `P.request(json, items, opts) -> path, headers, body`, with `opts = {key, model = <rest of the id>, effort, system}`.
  - **The parser:** `P.parser(json, handlers) -> feed(name, data), finish()`.
    - `finish()` is called by the chat when the connection ends.
    - If a `finish_reason` was seen and `done` wasn't called yet, it calls `done` with that stop.
  - **Titles:**
    - `P.titleRequest(json, key, firstUser, firstReply, model) -> path, headers, body`. Claude ignores `model` and keeps Haiku 5.5.
    - `P.titleText(json, body) -> string|nil`.
  - **Errors:** `P.describeError(json, status, body, retryAfter) -> string`.
  - **`claude.lua` changes:**
    - `P.id = "anthropic"` and `P.label = "Anthropic"`.
    - Its parser also returns a no-op `finish`.
    - Raw blocks are echoed for items whose provider is `anthropic` or `claude`.
    - Its describeError lines use `Anthropic` in place of `Claude`. Its existing tests are updated to match.

- [ ] **Step 1: Write the failing tests** in `tests/test_cc.lua`, with `run(fixture)` as in `test_claude.lua`:
  - `request_body_per_service`: golden decoded bodies for the three gateways.
    - `opencode` has `reasoning_effort = "low"`; the others have `reasoning = {effort = "low"}`.
    - `messages[1]` is `{role="system", content="SYS"}`.
    - There is no `max_tokens` (or the Task 1 value).
    - The path comes from the table, and the headers are the three of the Global Constraints.
  - `history_as_plain_text`: the items, in order:
    - a user message;
    - a Claude reply with `raw` (sent as its `text` only);
    - an old `openai` reply;
    - a note (skipped);
    - a whitespace-only reply (skipped);
    - a stopped reply (sent).

    The decoded `messages` match exactly.
  - `parse_vercel_text`, `parse_opencode_text`: the text equals the joined `delta.content`, `done.stop == "end"`, and `done.usage` has `cost`. The OpenCode usage chunk has empty `choices`.
  - `parse_reasoning`:
    - `thinking` is called before the first text for `vercel-reasoning.sse` (`reasoning`) and `opencode-reasoning.sse` (`reasoning_content`).
    - A chunk with only `reasoning_details` also calls it.
  - `parse_length`: `done.stop == "length"`.
  - `parse_openrouter_error`: `handlers.error("Provider disconnected unexpectedly")`, and `done` is never called.
  - `finish_without_done`: a stream cut after `finish_reason: "stop"` without `[DONE]`. `feed` doesn't call `done`, but `finish()` does, with `stop == "end"`.
  - `every_split`: each recorded stream fed through `src/sse.lua` at every chunk size from 1 to 64 gives the same text.
  - `title`: the request is non-streaming, `max_tokens == 300`, effort low, and `model` is the passed one. `titleText` of `vercel-title.json` is non-empty, and `titleText("not json")` is `nil`.
  - `describe_errors`:
    - 401 starts with `Vercel rejected the API key. Check Settings.` and includes the body's message.
    - `opencode-401.json` (type `server_error`) still says the key was rejected.
    - 402 gives `Your OpenRouter account is out of credit.`
    - 403 gives `OpenRouter refused this request.`
    - 429 with Retry-After 7 gives `Rate limited; try again in a moment. (7 s)`.
    - 503 gives `OpenCode is busy; try again.`
    - 418 gives `Vercel: HTTP 418.`
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement `src/providers/cc.lua`.** Parse each `data:` line with `json.decode` under `pcall`. `[DONE]` calls `done({stop, usage})`, where `stop` comes from the last `finish_reason` seen: `stop` is `end`, `length` is `length`, `content_filter` is `refusal`, anything else is `end`.
- [ ] **Step 4: Update `claude.lua` and its tests** as in Interfaces.
- [ ] **Step 5: Run, expect a pass:** `make test`.
- [ ] **Step 6: Commit.** `feat(cc): the Chat Completions provider for the gateways`

### Task 6: The chat controller and app wiring

**Files:**
- Modify: `src/chat.lua`, `src/app.lua`, `tests/test_chat.lua`

**Interfaces:**
- Consumes: Tasks 2, 3 and 5.
- Produces:
  - **The providers:** `deps.providers` is keyed by service id. `App.new` builds `{ anthropic = require("src.providers.claude"), opencode = CC.new(BY_ID.opencode), openrouter = CC.new(BY_ID.openrouter), vercel = CC.new(BY_ID.vercel) }`.
  - **The current model:** `chat:currentModel() -> full, serviceId, rest`. It comes from `prefs.model`, falling back to `Services.DEFAULT_MODEL` when that is invalid.
  - `chat:provider()` returns the current model's provider.
  - **Sending:** `chat:send(text)` and `chat:askFix(...)` behave as now, plus:
    - Before the user item, add the note `now <full>` (`kind = "model"`) when the chat's last assistant item, as a full id (`Services.full(item.provider, item.model)`), differs from the current model.
    - Then `store:pushRecent(full)` and save the prefs.
    - With no key for the current service, add the error note `Add your <Label> key in Settings (F5), or pick another model (F4).` and return `false, "nokey"`.
    - `chat:retry()` adds no switch note.
  - **New assistant items** have `provider = serviceId` and `model = full`; the chat file's `provider`/`model` likewise.
  - **Titles:** `P.titleRequest(json, key, first, reply, rest)`, sent to the chat's service.
  - **The refusal note** names `Services.short(self.model)`.
  - **The stream's end:** after `self.sse:finish()`, when nothing is done yet, the chat calls the parser's `finish`.

- [ ] **Step 1: Write the failing tests.** Change `setup()` to take `opts.model` (default `anthropic/claude-opus-5-5`) and to set `anthropic=` keys. Route `/v1/chat/completions` to `vercel-*` fixtures, and `/inference/openai/v1/chat/completions` to `opencode-*`. Add:
  - `gateway_reply`: with `model = "vercel/deepseek/deepseek-v4.1-flash-1017"`, a send streams `vercel-text.sse`.
    - The request goes to the Vercel base and path.
    - The stored item has `provider == "vercel"` and the full model.
    - The title arrives from `vercel-title.json`, and the title request's `model` is `deepseek/deepseek-v4.1-flash-1017`.
  - `switch_note`:
    - A reply from `anthropic/claude-opus-5-5`, then `prefs.model` changes to `vercel/google/gemini-3.8-flash`. The next send adds exactly one note `now vercel/google/gemini-3.8-flash` before the user item, and the note is not in the request.
    - Sending again on the same model adds no note.
    - An old item `{provider="claude", model="claude-opus-5-5"}` with current `anthropic/claude-opus-5-5` adds no note.
  - `recent_updated_on_send`: `prefs.recent[1]` is the sent model.
  - `no_key_note`: the Review Focus 4 case. The Vercel key is removed after the model is picked; `send` returns `false, "nokey"` with the exact note.
  - `reasoning_only_reply`: the Review Focus 5 case. A hand-built stream with reasoning chunks, `finish_reason: "stop"`, empty content and `[DONE]` stores no assistant item. A second send then streams normally.
  - `stream_closed_after_finish`: `[DONE]` is missing after `finish_reason: "stop"`. The reply completes, with no "Connection lost" note.
  - `old_claude_chat_continues`: a saved chat whose item has `provider = "claude"` and a `raw`. Opened, then sent on `anthropic/claude-opus-5-5`, the request's messages hold the `raw` blocks.
  - `refusal_note_short_name`: `content_filter` gives `deepseek-v4.1-flash-1017 declined to answer this.`
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement** in `src/chat.lua` and `src/app.lua`.
- [ ] **Step 4: Run, expect a pass:** `make test && make e2e`. The e2e tests that need the OpenAI provider may fail until Task 11. Note which ones; all the others must pass.
- [ ] **Step 5: Commit.** `feat(chat): one current model across every service, the switch note, recent models`

### Task 7: Remove the OpenAI provider

**Files:**
- Delete: `src/providers/openai.lua`, `tests/test_openai.lua`, `tests/fixtures/openai-*`
- Modify:
  - `src/theme.lua`
  - `tests/test_fixtures.lua`, `tests/test_programs.lua`, and any other test that still `require`s the OpenAI provider
  - `tools/record_stream.py`, `tests/tools/test_record_stream.py` (drop the `openai` cases)

**Interfaces:**
- Produces:
  - `theme.bar` is keyed `anthropic`, `opencode`, `openrouter`, `vercel`, `claude` (= anthropic) and `openai` (the old green), from `Services.color`.
  - `theme.match = rgb(255,210,90)`.
  - `theme.rule = rgb(85,85,85)`.

- [ ] **Step 1: Delete and update.** `grep -rn openai src tests tools` afterwards finds only:
  - `Services`' `openai` label and colour;
  - `theme.bar.openai`;
  - the old-item tests (Tasks 2, 3, 5 and 6).
- [ ] **Step 2: Run:** `make test && make test-tools`. Expect a pass.
- [ ] **Step 3: Commit.** `refactor: drop the OpenAI provider (old chats still open)`

### Task 8: Model lists: `Http.get`, the scanner, the fetcher

**Files:**
- Modify: `src/http.lua`, `tests/test_http.lua`
- Create:
  - `src/modellists.lua`, `tests/test_modellists.lua`
  - `tests/fixtures/lists/vercel.json`, `openrouter.json`: the real lists, fetched with `curl` (no key needed), cut to their first 12 entries, with the JSON kept valid.
  - `tests/fixtures/lists/opencode.json`: the whole list, fetched the same way (7 KB).

**Interfaces:**
- Consumes: `LISTS_OK`, `TWO_CONNECTIONS` (Task 1); `Store` (Task 3); `Services` (Task 2).
- Produces:
  - **`Http.get(net, base, path, headers) -> req`:** the same request object and states as `Http.post`.
  - **The scanner:** `ModelLists.scanner(serviceId) -> sc`.
    - `sc:feed(chunk)`.
    - `sc:finish() -> ids`: the kept ids in list order, without duplicates.
    - It keeps only §8.1's ids: `ModelLists.keep(serviceId, id, kind)`, where `kind` is Vercel's `type` (`nil` for the others).
  - **The fetcher:** `ModelLists.Fetcher.new({pc, store, busy}) -> f`. `busy()` is true while a chat reply is arriving; the app passes `function() return app.chat.state ~= "idle" end`.
    - `f:start(serviceIds)` queues services, and one list downloads at a time.
    - If `TWO_CONNECTIONS = no`, a queued download doesn't start while `busy()` is true; its group shows `Getting the model list...` meanwhile.
    - `f:tick()` is called every frame and returns `true` when something changed.
    - `f:cancel()`.
    - `f.state[serviceId]` is `"getting" | "failed" | nil`, and `f.err[serviceId]` is the reason.
    - **The request:** the service's `base` (or the test `<service>_base`) plus `listPath`, with `Authorization: Bearer <key>` when the service has a key.
    - **Saving:** a list is saved with `store:saveModelList` only after an HTTP 200 whose scan kept at least 1 id. Anything else sets `failed` with `err`, either `No WiFi`, `HTTP <status>` or `no models in the reply`, and leaves the old file untouched.
  - **Built-in fallback:** if `LISTS_OK = no` for a service, `ModelLists.BUILTIN[serviceId]` holds Task 1's ruled list, and the fetcher doesn't download that service.

- [ ] **Step 1: Write the failing tests.**
  - `test_http.lua`:
    - `get_streams_chunks`: through the fake's `conn:get`.
    - `get_bad_base`: the request fails with `bad base URL`.
  - `test_modellists.lua`:
    - `scan_every_split`: each fixture, fed at every chunk size from 1 to 97, gives the same ids as decoding it whole and filtering by §8.1.
    - `scan_ignores_escaped`: a description containing `\"id\":\"fake\"` adds no `fake` id.
    - `keep_rules`:
      - opencode keeps `deepseek-v4.1-flash`, `glm-5.3-flash`, `kimi-k3`, `minimax-m3`, `mistral-large-4` and `qwen3.8-max`;
      - it drops `qwen3.5-plus`, `claude-opus-5-5`, `gpt-6-luna`, `glm-5-free` and `big-pickle`;
      - vercel drops `type` `embedding` and `-batch` ids;
      - openrouter drops `:batch` ids.
    - `bounded_memory`: a generated 2 MB body of 4,000 models, fed in 16 KB chunks.
      - `collectgarbage("count")` grows by less than 400 KB over the baseline after the scan.
      - The scanner never holds more than one chunk plus the carried tail. Expose `sc.tailLen` for the test.
    - `fetch_saves`: a 200 with the Vercel fixture gives `models/vercel.txt` with `# fetched 1792000000` and the ids.
    - `fetch_failure_keeps_old`: the Review Focus 3 case. A saved list exists; a 503 sets `failed` with `HTTP 503`; an HTML 200 body sets `failed` with `no models in the reply`; a connection closed mid-body sets `failed`. In all three, the file is unchanged.
    - `fetch_cancel`: no write after `cancel`.
    - `fetch_waits_while_busy` (only if `TWO_CONNECTIONS = no`): no GET while `busy()` is true; it starts on the first tick after `busy()` turns false.
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement.** §8.3 says what the scan must survive. The builder chooses the method within the memory test.
- [ ] **Step 4: Run, expect a pass:** `make test`.
- [ ] **Step 5: Commit.** `feat(modellists): stream the gateways' model lists, keep only the ids`

### Task 9: The picker's logic

**Files:**
- Create: `src/picker.lua`, `tests/test_picker.lua`

**Interfaces:**
- Consumes: `Services` (Task 2), `FILTER_MS` (Task 1).
- Produces:
  - **The rows:** `Picker.build(input) -> rows, count`, where `input` is:
    - `current`: the current full id;
    - `recent`: a list of full ids;
    - `groups`: one per service in `Services.ORDER`, each `{ service, ids = {rest ids} | nil, state = "ok"|"nokey"|"getting"|"failed", err, age }`. The screen fills Anthropic's `ids` from `require("src.providers.claude").MODELS`, and the others from `store:modelList` (or `ModelLists.BUILTIN`);
    - `filter`: a string.

    Each row is one of:
    - `{kind="use", id}`;
    - `{kind="group", label, right}`;
    - `{kind="model", id, tag = "in use"|nil, hl = {a, b}|nil}`;
    - `{kind="text", text}`.

    `count` is the number of model rows.
  - **Filtering:**
    - `Picker.words(filter) -> {lowercase words}`.
    - `Picker.match(full, words) -> ok, a, b`, where `a..b` is the first word's span within `full`.
  - **Moving:** `Picker.step(rows, i, dir) -> j`, the next `model` or `use` row; `i` is kept if there is none.
  - **Ages:** `Picker.age(fetched, now) -> "today" | "<n>d" | nil`.
  - **The rows Picker.build makes:**
    - **Group order and contents:** Recent first, then the services in order.
    - **Group-row right text:** the count, plus the age for downloaded lists; for example `today  14`.
    - **Service states:**
      - `nokey` gives one text row, `No key yet: add one in Settings (F5)`.
      - `getting` gives `Getting the model list...`.
      - `failed` gives `Couldn't get the list: <err>. F2 tries again.`
    - **While filtering:** state rows and empty groups are hidden.
    - **The "Use" row** comes first when the trimmed filter is a valid full id (`Services.valid`) that isn't exactly a listed id.

- [ ] **Step 1: Write the failing tests.**
  - `groups_in_order`:
    - Recent, Anthropic, OpenCode, OpenRouter, Vercel, each with its model rows.
    - `tag == "in use"` on the current model in Recent and in its own group.
    - Anthropic's group, given the ids from `claude.lua`'s `MODELS`, lists `anthropic/claude-opus-5-5`, `-sonnet-5-5`, `-haiku-5-5` and `-fable-5-1` in that order.
  - `states`: the three text rows, exactly; `count` excludes them.
  - `filter_words`:
    - `"ds flash"` doesn't match `vercel/deepseek/deepseek-v4.1-flash-1017` (no `ds` in it).
    - `"deep flash"` matches it, with `hl` on `deep`.
    - `"VERCEL gem"` matches `vercel/google/gemini-3.8-flash`.
    - Empty groups are hidden.
  - `filter_literal`: the Review Focus 1 case. `"gpt-5.6"`, `"("`, `"%"` and `"["` raise nothing, and `"5.6"` doesn't match `gpt-5x6`.
  - `use_row`: the Review Focus 2 case.
    - `"openrouter/qwen/qwen3.8-max"`, when it isn't listed, gives a first `use` row.
    - An exactly listed id gives no `use` row.
    - None for `"openrouter/"`, `"foo/bar"`, `"Vercel/x"`, `"vercel/a b"`, `"vercel/x/"` or 121 characters.
  - `step_skips`: Up and Down skip group and text rows and stay put at the ends.
  - `age`: the same day gives `today`; 3 days 2 hours later gives `3d`; `nil` stays `nil`.
  - `speed`: building and filtering 800 ids with `"flash"` takes under 20 ms on the host (a guard, not the device figure). If `FILTER_MS > 50`, also test that narrowing an extended filter uses the previous result.
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement `src/picker.lua`.** It draws nothing.
- [ ] **Step 4: Run, expect a pass:** `make test`.
- [ ] **Step 5: Commit.** `feat(picker): the model picker's rows, filter and selection`

### Task 10: The picker screen and the chat screen changes

**Files:**
- Create: `src/screens/picker.lua`, `tests/test_screen_picker.lua`
- Modify: `src/app.lua` (`App.SCREENS.picker`), `src/screens/chat.lua`, `tests/test_screen_chat.lua`

**Interfaces:**
- Consumes: `Picker` (Task 9), `ModelLists.Fetcher` (Task 8), `store:modelList` and `pushRecent` (Task 3), `theme.match`/`rule`/`bar` (Task 7).
- Produces:
  - **`app:go("picker")`:**
    - On enter: it reads each service's saved list, starts the fetcher for keyed services with no list, and selects the current model's Recent row.
    - On leave: it cancels the fetcher.
    - On a pick: it sets `prefs.model`, calls `pushRecent`, saves the prefs, and does `app:go("chat")`.
  - **The layout** follows §5.1 and mockups 09-11:
    - a `W.TextField` filter at y = header + 4 across x 4-316, drawing the hint when empty;
    - rows of 13 px in 6x8;
    - a 2 px scroll bar at x 317;
    - the footer `Enter pick  F2 refresh  Esc back` (`Enter pick  Esc clear` while filtering), with `<n> models` or `<n> match` at the right.
  - **The keys** follow the table in §5.1.
  - **The chat screen (§5.2):**
    - F4 opens the picker.
    - The intro shows the dot, the full id, and the key caps F1 `Recent chats`, F4 `Model`, F5 `Settings`.
    - The footer's right side is `Services.short` of the model, cut with `..`.
    - Reply bars and dots take `theme.bar[item.provider]`.
    - The `model` note draws dim and centred between two rules, as in mockup 13.

- [ ] **Step 1: Write the failing screen tests**, with the fake `picocalc`:
  - `opens_on_current`: F4 from chat opens `picker`, and the selected row is the current model in Recent.
  - `type_filters_enter_picks`:
    - Typing `gem`, then Down, then Enter sets `prefs.model` to the selected `vercel/google/gemini-3.8-flash`.
    - The app is back on `chat`, and `prefs.recent[1]` is that id.
    - The chat footer's right side reads `gemini-3.8-flash`.
  - `esc_clears_then_leaves`: the first Esc empties the filter and stays; the second goes to `chat` with `prefs.model` unchanged.
  - `use_typed_id`: typing `openrouter/qwen/qwen3.8-max`, then Enter, picks it.
  - `fetch_on_open`:
    - A keyed service with no list file makes one GET to its list path.
    - `Getting the model list...` is drawn.
    - After the fake answers, the ids are drawn and the file is saved.
    - Leaving mid-fetch cancels it.
  - `f2_refetches`: F2 GETs every keyed service's list again.
  - `intro_and_footer`: the new chat intro draws the full id and the three key caps. A chat with a Vercel reply draws its bar in `{215,215,215}`.
  - `switch_note_drawn`: a `model` note draws in the dim colour with two rule rectangles.
- [ ] **Step 2: Run, expect failures.** `make test`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect a pass:** `make test`.
- [ ] **Step 5: Screenshots.** Run the picker in the simulator with fixture lists (as the Task 11 e2e will) and compare by eye with mockups 09-13. Fix spacing that drifts.
- [ ] **Step 6: Commit.** `feat(picker): the F4 model picker screen; the chat shows the model id`

### Task 11: Settings, Recent chats and the program error screen; e2e

**Files:**
- Modify:
  - `src/screens/settings.lua`, `src/screens/lists.lua`, `src/screens/program_error.lua`
  - `tests/test_screen_settings.lua`, `tests/test_screen_lists.lua`
  - `tests/e2e/fake_api.py`, `tests/e2e/conftest.py`, `tests/e2e/test_chat.py`, `tests/e2e/test_lists_settings.py`, `tests/e2e/test_programs.py`
- Create: `tests/e2e/test_picker.py`

**Interfaces:**
- **Settings (§5.4, mockup 14):**
  - Section labels `API keys` and `Replies`, each with a rule.
  - Key rows Anthropic, OpenCode, OpenRouter, Vercel, then Thinking, Reply font, Instructions. Up and Down skip the labels.
  - The mask keeps `sk-ant-`, `sk-or-v1-` or `sk-`.
- **Recent chats:** the second line is `Services.label(row.provider)` plus the count, and the dot is `theme.bar[row.provider]`.
- **The program error screen:** the button is `Ask the model to fix`; the hint is `<Services.short(current)> can see the error and the code and send back a fixed version.`
- **The fake API (e2e):**
  - It routes by path:
    - `/v1/messages` to `anthropic-*` (rename the `claude-*` fixtures it reads, or map `anthropic` to `claude`);
    - `/v1/chat/completions` to `vercel-*`;
    - `/api/v1/chat/completions` to `openrouter-*`;
    - `/inference/openai/v1/chat/completions` to `opencode-*`.
  - The three list paths serve `tests/fixtures/lists/<service>.json`.
  - `@<name>` messages pick fixtures, as now.
  - `@prog-<name>` works in the CC stream format too.
- **The e2e fixture:** `llmchat` becomes `start(model="anthropic/claude-opus-5-5", keys=True, prefs=None)`.
  - It writes `model` and all four `<service>_base` overrides.
  - With `keys`, it writes fake keys for all four services.

- [ ] **Step 1: Write the failing tests.**
  - **Host:**
    - `settings_rows`: the seven rows in order, with the labels not focusable.
    - `settings_save_keys`: Enter on Vercel, type, Enter writes `vercel=`.
    - `lists_service_label`: `Vercel  4 messages`, and `Anthropic` for an old `claude` row.
    - `program_error_labels`: the button text and the hint.
  - **e2e** (`tests/e2e/test_picker.py` and updates):
    - `test_pick_and_send`: F4, type `gemini`, Enter, then send. The request goes to `/v1/chat/completions` with `model` `google/gemini-3.8-flash`, and the reply streams.
    - `test_switch_line`: a Claude reply, then a pick, then a send draws the `now ...` line. Use a screenshot check and the saved chat file.
    - `test_gateway_401`: `@401` on Vercel shows `Vercel rejected the API key. Check Settings.`
    - `test_settings_keys`: the four keys are saved to `keys.txt`.
    - `test_old_claude_chat`: a staged old chat file (`provider: "claude"`, with `raw`) continues on `anthropic/`, and the request holds the `raw`.
    - The existing OpenAI e2e cases become Vercel ones.
- [ ] **Step 2: Run, expect failures.** `make test && make e2e`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect a pass:** `make test && make e2e && make test-tools`. All of them pass.
- [ ] **Step 5: Commit.** `feat(settings): a key per service; lists and the error screen name services`

### Task 12: Docs, the main spec, and device checks

**Files:**
- Modify:
  - `docs/superpowers/specs/2026-10-25-llmchat-design.md`: sections 2, 5.1-5.4, 6, 8.1, 8.2, 8.4 and 11 are made to match the gateways spec. Its §6.3 (OpenAI) is replaced by the CC provider. The header notes the change and links the gateways spec.
  - `README.md`: the intro, set-up (the four key names, `keys.txt`), the keys tables (F4, the picker table) and the Development section (`<service>_base`).
  - `docs/device-checklist.md`: the OpenAI rows become a gateway chat on each keyed service. New rows: list downloads (time, lowest free heap), filtering, the switch line.
  - `docs/follow-ups.md`: drop the OpenAI items. Add §13's later items, and Task 1's open points if any.

- [ ] **Step 1: Update the docs.** `grep -rn -i openai README.md docs/device-checklist.md docs/superpowers/specs/2026-10-25-llmchat-design.md` finds only history (old chats, the decision to drop it).
- [ ] **Step 2: Device checks.**
  - Check the device is idle and ask the owner first.
  - Stage the app at `/apps/.dev/llmchat`. Add only the keys of the services under test to its `/data/net.picodeck.llmchat/keys.txt`, which is the app's own data folder. Do not read or overwrite an existing `keys.txt` there: if one exists, ask the owner.
  - Run the new checklist rows: one short real chat each on Anthropic, Vercel and OpenCode, plus OpenRouter if the owner has renewed the key; the list downloads; filtering; the switch line.
  - Log the spend. Then remove what was added.
- [ ] **Step 3: Run everything:** `make test && make e2e && make test-tools`. Expect a pass.
- [ ] **Step 4: Commit.** `docs: gateways and the model picker in the spec, README and device checklist`
