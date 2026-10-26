# Gateway API facts: OpenRouter, Vercel AI Gateway, OpenCode (Zen/Console, Go)

Fetched 2026-10-26 from the vendors' own docs (markdown versions) and public model lists. No keys used, no authenticated requests, nothing signed up for.
Notation: **[doc]** = stated in vendor docs (URL given); **[measured]** = I fetched it myself; **[unverified]** = not in the docs I read, or inferred.

Shorthand: CC = Chat Completions (`/chat/completions`), RESP = Responses (`/responses`), MSG = Anthropic Messages (`/messages`).

---------------------------------------------------------------------------------------------------

## 1. OpenRouter

### Base URL and auth
- Base URL `https://openrouter.ai/api/v1` [doc: https://openrouter.ai/docs/api-reference/authentication ; OpenAPI `servers` at https://openrouter.ai/openapi.json].
- Auth: `Authorization: Bearer <key>` [doc: https://openrouter.ai/docs/api-reference/authentication]. The OpenAPI security scheme is only "bearer" (https://openrouter.ai/openapi.json).
- Optional attribution headers [doc: https://openrouter.ai/docs/api-reference/overview#headers]:
  - `HTTP-Referer`: app URL
  - `X-OpenRouter-Title`: app title (`X-Title` is "also accepted")
  - `X-OpenRouter-Categories`: marketplace categories
  None is required. Other optional headers: `x-session-id` (<=256 chars, sticky routing/grouping) [doc: https://openrouter.ai/docs/guides/best-practices/prompt-caching].
- Key prefix: `sk-or-v1-` (the key listing example shows `"label": "sk-or-v1-abc...123"`) [doc: https://openrouter.ai/docs/guides/overview/auth/provisioning-api-keys]. That is a management-API example, not a stated format guarantee, so treat the prefix check as a soft warning.
- Response header `X-Generation-Id` on all endpoints [doc: https://openrouter.ai/docs/api-reference/streaming].

### API shapes
| Shape | Path | Notes |
|---|---|---|
| CC | `POST https://openrouter.ai/api/v1/chat/completions` | All models. OpenAI-normalised. [doc: overview page; OpenAPI paths] |
| RESP | `POST https://openrouter.ai/api/v1/responses` | Listed in OpenAPI `paths`. Streaming usage is in `response.completed`. [doc: https://openrouter.ai/docs/api-reference/streaming] |
| MSG | `POST https://openrouter.ai/api/v1/messages` | Anthropic format, works for every model: "OpenRouter normalizes both into the unified `reasoning` parameter, so they work on every reasoning model, not only Claude" [doc: https://openrouter.ai/docs/use-cases/reasoning-tokens]. |

- For Anthropic SDK clients, base URL is `https://openrouter.ai/api` (SDK appends `/v1/messages`), auth `ANTHROPIC_AUTH_TOKEN` = `Authorization: Bearer`; `x-api-key` is NOT the documented path [doc: https://openrouter.ai/docs/guides/coding-agents/claude-code-integration].
- MSG request schema `required: ["model","messages"]`, so `max_tokens` is not required by the OpenRouter schema (differs from Anthropic) [measured from https://openrouter.ai/openapi.json components.schemas.MessagesRequest]. The Anthropic-path example sends `max_tokens: 1024` anyway. Send it to be safe.
- MSG streaming: the OpenAPI declares `text/event-stream` with `event: content_block_delta` and a `MessagesStreamEvents` union including `message_start` [measured: https://openrouter.ai/openapi.json]; docs say usage arrives in `message_delta` before `message_stop` [doc: https://openrouter.ai/docs/api-reference/streaming]. So Anthropic event names are the same and the existing Claude parser should work. Whether it is byte-identical (e.g. extra `ping` events, extra fields) is [unverified].
- Model routing: whichever of CC/RESP/MSG is used, any model id works on any path (unified gateway). This is the opposite of OpenCode.

### Model ids and the models list
- Format `author/slug`, optional `:variant` suffix (e.g. `:free`, `:batch`) [doc: limits page mentions `:free`; list shows `:batch`].
- Aliases starting with `~` track the latest: `~anthropic/claude-haiku-latest`, `~openai/gpt-sol-latest`, `~deepseek/deepseek-pro-latest` [measured: https://openrouter.ai/api/v1/models].
- Examples from the live list [measured: https://openrouter.ai/api/v1/models, 2026-10-26]:
  - Claude: `anthropic/claude-sonnet-5.5`, `anthropic/claude-opus-5.5`, `anthropic/claude-haiku-5.5`
  - GPT: `openai/gpt-5.6-luna`, `openai/gpt-5.6-terra`
  - Kimi: `moonshotai/kimi-k3`, `moonshotai/kimi-k3.1-pro`
  - GLM: `z-ai/glm-5.3`, `z-ai/glm-5.3-flash`
  - Qwen: `qwen/qwen3.8-flash`, `qwen/qwen3.8-max-0902`
  - DeepSeek: `deepseek/deepseek-v4-pro-0813`, `deepseek/deepseek-v4.1-flash`
- Models endpoint: `GET https://openrouter.ai/api/v1/models`. The OpenAPI operation has no `security` requirement, and I fetched it unauthenticated (HTTP 200) [measured; docs: https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties].
- Size [measured]: **791,103 bytes** uncompressed (467 models); ~80.6 KB if gzip is negotiated. `Cache-Control: public, max-age=120`.
- It is filterable and pageable, which matters on a 5 MB device [doc/OpenAPI: https://openrouter.ai/openapi.json, `/models` parameters]: `limit` (max 1000), `offset`, `q` (free text), `output_modalities`, `supported_parameters`, `model_authors`, `category`, `sort`, etc. Measured: `?limit=20&output_modalities=text` = 30,965 bytes (20 models); `?q=claude&limit=5` works. Each entry is large (~1.7 KB: description, pricing, architecture, benchmarks), so even 20 entries is ~31 KB. A hand-curated model list in the app is much cheaper.
- Per-model reasoning metadata: `reasoning.supported_efforts / default_effort / mandatory / supports_max_tokens` [doc: https://openrouter.ai/docs/use-cases/reasoning-tokens]. Also `supported_parameters` per model (list includes `reasoning`, `reasoning_effort`, `include_reasoning`) [measured].

### CC streaming
- SSE with `data: {json}` lines separated by blank lines; ends with `data: [DONE]` [doc: https://openrouter.ai/docs/api-reference/streaming].
- Keep-alive: comment lines `: OPENROUTER PROCESSING` sent "occasionally to prevent connection timeouts"; the doc says to skip any line starting with `:` before JSON-parsing [doc: same]. So idle-based read timeouts are mitigated by this, but the frequency/interval is not documented [unverified].
- Usage: always reported on Chat Completions with no opt-in. "every stream ends with an extra chunk that carries the `usage` object... sent just before the `[DONE]` message". Deviation from OpenAI: this chunk has a non-empty `choices` array: one choice with `delta:{"content":"","role":"assistant"}` repeating `finish_reason`/`native_finish_reason` [doc: https://openrouter.ai/docs/api-reference/streaming]. So `finish_reason` appears twice; treat the usage frame as accounting only. `usage` includes `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_tokens_details.{cached_tokens,cache_write_tokens}`, `completion_tokens_details.reasoning_tokens`, `cost` [doc: https://openrouter.ai/docs/api-reference/overview]. `stream_options.include_usage` is not mentioned as required [doc silent on whether it is accepted].
- Reasoning in deltas [doc: https://openrouter.ai/docs/use-cases/reasoning-tokens]:
  - `delta.reasoning` (string) is the primary field ("Reasoning tokens will appear in the `reasoning` field of each message").
  - `delta.reasoning_details` is an array of typed objects (`reasoning.text` with `text`/`signature`/`id`/`format`/`index`, plus encrypted/summary types). Encrypted content may appear as `[REDACTED]` in streams.
  - `reasoning_content` is documented only as an input alias ("You can also use `reasoning_content` as an alias - it functions identically to `reasoning`") when sending history back. Whether it is ever emitted in stream output is [unverified]; a client that reads `reasoning` and falls back to `reasoning_content` is safe.
  - Some models never return reasoning (OpenAI o-series noted).
- Requesting effort [doc: same page]: `"reasoning": {"effort": "max"|"xhigh"|"high"|"medium"|"low"|"minimal"|"none"}` OR `{"max_tokens": N}` (not both), plus `"exclude": true`, `"enabled": true`. Legacy `include_reasoning: true/false`. Whether the OpenAI-style top-level `reasoning_effort` is accepted on CC is not stated in the reasoning page, but `reasoning_effort` appears in model `supported_parameters` [measured], so likely yes [unverified]. Check each model's `reasoning.supported_efforts` and don't send `none` to `mandatory` models.
- Gotcha: reasoning tokens count against `max_tokens` on most providers; a small cap can yield `finish_reason: "length"` with empty content [doc: same page]. Anthropic: `max_tokens` must be strictly greater than the reasoning budget; min reasoning budget 1024 [doc: same page].
- Mid-stream errors [doc: https://openrouter.ai/docs/api-reference/streaming#handling-errors-during-streaming]: HTTP stays 200 once headers are sent; a single SSE chunk arrives with a top-level `error` object AND `choices:[{"index":0,"delta":{"content":""},"finish_reason":"error"}]`:
  `data: {"id":"cmpl-abc123","object":"chat.completion.chunk",...,"provider":"openai","error":{"code":"server_error","message":"Provider disconnected unexpectedly"},"choices":[{...,"finish_reason":"error"}]}`
  Stream ends after it. It "can be the first and only event", so a 200 with an error chunk and no content is a failure. Note `error.code` can be a string here (`"server_error"`) while pre-stream it is a number.
- `finish_reason` normalised to: `tool_calls`, `stop`, `length`, `content_filter`, `error`; raw provider value in `native_finish_reason` [doc: https://openrouter.ai/docs/api-reference/overview].

### Errors
- Body shape (before the stream starts): `{"error":{"code":<int>,"message":"...","metadata":{...}}}`; HTTP status equals `error.code` [doc: https://openrouter.ai/docs/api-reference/errors].
- Codes [doc: same]: 400 bad request; 401 invalid credentials/disabled key; **402 insufficient credits**; 403 forbidden (moderation, guardrail, or **budget/key limit exceeded**, with `metadata.limit_source`); 408 timeout; 429 rate limited; 502 model down/invalid upstream response; 503 no provider meets routing requirements.
- `Retry-After` header may appear on 429, 503, and some 402 (`metadata.limit_source == "openrouter_in_flight_budget"`) [doc: same]. A 402 without the header is not retryable. Moderation 403s carry `metadata.reasons/flagged_input/provider_name/model_slug`.
- On `/messages` guardrail blocks come back as an Anthropic-style `permission_error` envelope [doc: same page, "Anthropic Messages" section].
- Free models (`:free`) have per-minute and per-day request caps; 429 [doc: https://openrouter.ai/docs/api-reference/limits].

### Prompt caching
- Automatic for OpenAI, DeepSeek, Gemini 2.5+ etc.; **opt-in for Anthropic and Alibaba** [doc: https://openrouter.ai/docs/guides/best-practices/prompt-caching].
- Anthropic via the CC path: `cache_control: {"type":"ephemeral"}` (optionally `"ttl":"1h"`) on a content block (max 4 explicit breakpoints), OR one top-level `cache_control` on the request body ("automatic caching": breakpoint moves to the last cacheable block). Top-level automatic caching is supported on Anthropic, Vertex, Azure, Bedrock providers [doc: same page]. The Responses API supports only the top-level form [doc: same].
- For a 16 KB system prompt + client-side history, the top-level `cache_control` on CC is the cheapest change: add it once to the body. A system prompt sent as a content-block array `[{"type":"text","text":...,"cache_control":{"type":"ephemeral"}}]` also works. Writes cost 1.25x (5 min) or 2x (1 h) input price, reads 0.1x [doc: same, Anthropic section].
- Sticky routing keeps the cache warm (keyed on first system + first non-system message hash, or `session_id`/`x-session-id`; 10-min idle expiry) [doc: same].
- OpenAI GPT-5.6+: cache writes billed at 1.25x even with automatic caching; can disable via `prompt_cache_options.mode: "explicit"` [doc: same]. Relevant for the title request: a sub-1024-token prompt is never cached.
- Cache usage shows in `usage.prompt_tokens_details.cached_tokens` / `cache_write_tokens`.

### Things that could break a minimal client
- Comment lines `: OPENROUTER PROCESSING` must be skipped (lines starting with `:`).
- Final usage chunk has non-empty `choices` with empty-content delta and a duplicate `finish_reason`.
- A mid-stream error chunk looks like a normal chunk but with top-level `error`; HTTP is 200.
- `delta.content` can be `null`/`""`; reasoning arrives in a separate `delta.reasoning` field before content.
- `max_tokens` is optional, but a small value plus reasoning gives empty output.
- Models list is ~790 KB: never fetch it unfiltered on-device.

---------------------------------------------------------------------------------------------------

## 2. Vercel AI Gateway

### Base URL and auth
- CC and RESP: `https://ai-gateway.vercel.sh/v1`; MSG: base `https://ai-gateway.vercel.sh` (path `/v1/messages`) [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions ; .../anthropic-messages-api ; .../responses].
- Auth: `Authorization: Bearer <AI Gateway API key or OIDC token>` on all paths. On MSG, `x-api-key: <key>` is also accepted [doc: .../openai-chat-completions and .../anthropic-messages-api#authentication]. "If an API key is specified it will take precedence over any OIDC token, even if the API key is invalid."
- Key prefix: `vck_` (appears as `"api_key": "vck_..."` in the compromised-secret example) [doc: https://vercel.com/docs/ai-gateway/authentication-and-byok/api-keys]. Only one doc mention; the docs never state the format normatively, so treat as a soft check.
- Optional headers: the CORS allow-list on `/v1/models` includes `http-referer`, `x-title`, `x-session-id`, `x-session-affinity`, `anthropic-beta`, `anthropic-version`, `x-api-key` [measured: response headers of https://ai-gateway.vercel.sh/v1/models]. Their semantics (attribution for http-referer/x-title) are [unverified]; nothing is required. Gateway options go in the JSON body under `providerOptions.gateway` [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis].

### API shapes
| Shape | Path | Notes |
|---|---|---|
| CC | `POST /v1/chat/completions` | Any model. [doc: openai-chat-completions page] |
| RESP | `POST /v1/responses` | "Responses and OpenResponses share `/v1/responses`" [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis]. Model id is `provider/model` in the docs example (`anthropic/claude-sonnet-5` shown for Responses params) [doc: .../responses]. |
| MSG | `POST /v1/messages` (+ `/v1/messages/count_tokens`, batches) | "implements the same specification as the Anthropic Messages API"; `max_tokens` required; "Use any model available through the gateway" [doc: .../anthropic-messages-api]. |
- All shapes accept any `provider/model` id (a unified gateway); the docs don't restrict by family.
- MSG streaming event names are the standard ones: `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta` (stop reason + usage), and presumably `message_stop` [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis/anthropic-messages-api/streaming ; list there stops before `message_stop` in my read, so `message_stop`/`ping` are inferred, [unverified]]. Anthropic SDK is documented as working with just `baseURL: 'https://ai-gateway.vercel.sh'`, so the existing Claude parser should be reusable.
- Claude Code compatibility: `ANTHROPIC_BASE_URL=https://ai-gateway.vercel.sh`, `ANTHROPIC_AUTH_TOKEN=<key>`, `ANTHROPIC_API_KEY=""` [doc: .../anthropic-messages-api#configuring-claude-code].

### Model ids and models list
- Format `provider/model`, mostly dotted versions [doc: quickstart `anthropic/claude-sonnet-5`; measured list].
- Examples [measured: https://ai-gateway.vercel.sh/v1/models, 480 models]:
  - Claude: `anthropic/claude-sonnet-5.5`, `anthropic/claude-opus-5.5`, `anthropic/claude-haiku-5.5`
  - GPT: `openai/gpt-5.6-luna`, `openai/gpt-6-luna`
  - Kimi: `moonshotai/kimi-k3`, `moonshotai/kimi-k3.1-pro`
  - GLM: `zai/glm-5.3` (provider slug is `zai`, differs from OpenRouter's `z-ai`)
  - Qwen: `alibaba/qwen3.7-flash`, `alibaba/qwen3.7-max` (provider slug `alibaba`, not `qwen`)
  - DeepSeek: `deepseek/deepseek-v4-pro`, `deepseek/deepseek-v4.1-flash`
  - Variants: `-batch`, `-fast` suffixes exist as separate ids.
- Models endpoint: `GET https://ai-gateway.vercel.sh/v1/models` (also `GET /v1/models/{model}`). **"This endpoint requires no authentication"** [doc: https://vercel.com/docs/ai-gateway/models-and-providers#finding-models; confirmed by my unauthenticated fetch, HTTP 200]. The OpenAI-compat page's example does send a Bearer key, but it isn't needed.
- Size [measured]: **543,819 bytes** uncompressed (480 models); ~64.1 KB if gzip negotiated. `cache-control: public`. Entry fields: `id, name, description, context_window, max_tokens, type, tags, supported_parameters, reasoning_options, pricing`. No filter/pagination params documented; `include_availability` (authenticated) exists [doc: models-and-providers page]. Entries have `type: "language"` etc., so you must filter embeddings/image models client-side.

### CC streaming
- SSE, OpenAI format; `data: {chunk}` lines, **ends with `data: [DONE]`** [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions/streaming].
- Keep-alive comments: not documented [doc silent]. Timeouts/idle behaviour: not documented. Provider timeouts only for BYOK credentials [doc: .../advanced#provider-timeouts].
- Usage in stream: doc silent on `stream_options.include_usage` or when/whether a usage chunk is sent [doc silent; unverified]. Safest to send `"stream_options":{"include_usage":true}` and handle both outcomes. Non-streaming `usage` is documented, with `completion_tokens_details.reasoning_tokens`.
- Reasoning: streamed in **`delta.reasoning`** (string); also `delta.reasoning_details` array (incremental) for providers that emit them [doc: https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions/reasoning]. `reasoning_content` is not mentioned.
- Effort request: `"reasoning": {"effort": "none|minimal|low|medium|high|xhigh|max"}` OR `{"max_tokens": N}` (not both), `enabled`, `exclude`; also the standard top-level `reasoning_effort`, "an alias for `reasoning.effort`", nested value wins if both [doc: same page]. Per-model controls come from `reasoning_options` in the models list. Newer Claude (Opus 4.7+) may omit reasoning text even when thinking runs unless `thinking.display: 'summarized'` is set via provider options [doc: same page].
- Mid-stream error format and finish_reason set: not documented in the pages I fetched [doc silent; unverified]. Assume OpenAI-style finish reasons (`stop`, `length`, `tool_calls`, `content_filter`).

### Errors
- CC error shape: `{"error":{"message":"...","type":"invalid_request_error","param":"model","code":"missing_parameter"}}` [doc: openai-chat-completions page#error-handling]. Listed statuses: 400, 401, 403, 404, 429, 500.
- **402** appears for budgets: `{"error":{"message":"Project budget exceeded. Current spend: $200.00, limit: $200.00...","type":"quota_for_entity_exceeded"}}` [doc: https://vercel.com/docs/ai-gateway/observability-and-spend/budgets#when-a-budget-is-exceeded]. Out-of-credits behaviour (no budget) is not spelled out; the pricing page says credits or a payment method are needed [doc: .../pricing]; the status code for that is [unverified].
- Free tier: rate limited per model, returns 429; subset of models only [doc: https://vercel.com/docs/ai-gateway/pricing].
- 5xx: gateway internal errors surface as 500; SDK wrappers may mask a budget 402 as an internal-server-error class, so check status/body [doc: budgets page].

### Prompt caching
- Default: gateway passes through unmodified; OpenAI/Google/DeepSeek cache implicitly; **Anthropic needs `caching: 'auto'` or manual markers** [doc: https://vercel.com/docs/ai-gateway/models-and-providers/automatic-caching].
- Manual: `cache_control: {"type":"ephemeral"}` placed on a **message object** (`{"role":"user","content":"...","cache_control":{...}}`) on the CC path; works for Anthropic across Anthropic/Vertex/Bedrock [doc: .../openai-chat-completions/advanced#prompt-caching]. (Note: the Vercel CC example puts `cache_control` on the message itself, not on a content block; block-level on CC is [unverified].)
- Auto: `"caching": "auto"` (documented under `providerOptions.gateway`; the Responses example shows it top-level with `cache_ttl: "5m"|"1h"`). Adds breakpoints on the last message and on the message before the last user message (fallback system message). Supported for Anthropic (direct/Vertex/Bedrock), MiniMax, Alibaba [doc: automatic-caching page].
- On the MSG path `cache_control` is passed through to Anthropic, Vertex-Anthropic, Bedrock-Anthropic [doc: .../anthropic-messages-api, note near the end].
- Session affinity (keep a conversation on the provider holding its cache): `x-session-id` / `x-session-affinity` headers appear in CORS list; semantics in https://vercel.com/docs/ai-gateway/models-and-providers/session-affinity (not read in detail).

### Things that could break a minimal client
- Provider slugs differ from OpenRouter (`zai/`, `alibaba/`, not `z-ai/`, `qwen/`).
- MSG requires `max_tokens`. CC `max_tokens` is optional.
- Usage-in-stream and keep-alive behaviour are undocumented; verify empirically with a real key.
- Models list is ~540 KB with no filter params documented.

---------------------------------------------------------------------------------------------------

## 3. OpenCode

### Which products issue keys a third-party client can use
- **OpenCode Zen is now called "Console" / pay-as-you-go ("OpenCode Console provides a list of models tested and verified... Sign in, add credits, and get an API key to use them with OpenCode or another coding agent")** [doc: https://opencode.ai/v2/docs/console/models/ (same content at https://opencode.ai/docs/zen/)]. Keys are created in the Console: personal keys (Account > Personal API keys) or service-account keys; usable from any client [doc: https://opencode.ai/v2/docs/console/api/].
- **OpenCode Go** ($10/month "Go", $40/month "Go Plus") is a subscription with a separate endpoint set; it uses the same Console API key from a workspace with a Go subscription [doc: https://opencode.ai/v2/docs/console/go/ ; https://opencode.ai/v2/docs/console/harnesses/claude-code/]. Policy caveat: "Go is designed for OpenCode and other coding agents that produce similar types of requests. Traffic is monitored for abuse"; clients "should: send typical coding agent traffic; identify itself with its own user agent (e.g. `my-coding-agent/1.0`); send a stable session ID in `x-opencode-session` per conversation" [doc: Go page "Where can I use it?"]. A generic chat app is a grey area for Go; pay-as-you-go Console has no such restriction stated.
- Free-tier models (names ending `-free`, plus `big-pickle`) **return 403 outside OpenCode, "even with an API key"** [doc: https://opencode.ai/v2/docs/console/api/inference/]. So a third-party app must use paid models or Go.
- Key format: `oc_sk_...` (e.g. `oc_sk_1a2b3c4d5e6f_...`) [doc: https://opencode.ai/v2/docs/console/api/]. Keys optionally expire; revoked/expired keys return 401.
- Docs-site note: https://opencode.ai/docs/zen/ and /docs/go/ serve the same content as the /v2/docs/console pages; /docs/console/api/* 404s but /v2/docs/console/api/* works.

### Base URLs and auth
- Pay-as-you-go: `https://opencode.ai/inference/...`; Go: `https://opencode.ai/inference/go/...` [doc: models page and Go page endpoint tables].
- Auth: `Authorization: Bearer <oc_sk_...>` [doc: https://opencode.ai/v2/docs/console/api/inference/]. CORS allow-headers of the models endpoint include `X-Api-Key` and `X-Opencode-Org-Id` [measured response headers]; `x-api-key` on Messages is plausible but [unverified].
- The older path `https://opencode.ai/zen/v1/...` still responds (e.g. `/zen/v1/models` returns the same 85-model body as `/inference/v1/models`) [measured]. The docs now say `/inference/...`; use that. Chat/Responses/Messages paths under the old `/zen/v1/` root were not tested (would need auth).

### API shapes: routed by model family (one API per model)
Paths [doc: https://opencode.ai/v2/docs/console/api/inference/]:
| Shape | Pay-as-you-go path | Go path | Serves |
|---|---|---|---|
| CC | `/inference/openai/v1/chat/completions` | `/inference/go/openai/v1/chat/completions` | open models: Kimi (k2.5, k2.6, k2.7-code, k3), GLM (5, 5.1, 5.2, 5.3, 5.3-flash), DeepSeek V4.x, MiniMax, Mistral Large 4, Qwen3.8 Max (pay-go), Big Pickle and other free models |
| RESP | `/inference/openai/v1/responses` | `/inference/go/openai/v1/responses` | GPT models (gpt-5.x, gpt-6.x), Grok, Muse |
| MSG | `/inference/anthropic/v1/messages` | `/inference/go/anthropic/v1/messages` | Claude models and most Qwen models (qwen3.5/3.6-plus, 3.8-flash; in Go also qwen3.8-max, qwen3.7-plus, minimax-m3) |
| Gemini | `/inference/google/v1beta/models/<model>:generateContent` (`:streamGenerateContent`) | `.../go/google/...` | Gemini |
- "Each model is served by one API family. See the model endpoints table, or fetch the live list" [doc: same]. The per-model table is at https://opencode.ai/v2/docs/console/models/ (pay-go) and https://opencode.ai/v2/docs/console/go/ (Go). Family can differ between tiers: `qwen3.8-max` is CC on pay-go but MSG on Go; `minimax-m3` is CC on pay-go but MSG on Go. The models-list JSON does NOT say which path a model uses, so the app must carry a table (or prefix rule) itself.
- Claude on MSG: `max_tokens` required [doc: inference page]. Claude Code is documented to work with `ANTHROPIC_BASE_URL=https://opencode.ai/inference/anthropic` (client appends `/v1/messages`), `ANTHROPIC_AUTH_TOKEN` [doc: https://opencode.ai/v2/docs/console/harnesses/claude-code/]. So the existing Anthropic provider could point at OpenCode for Claude (and Qwen) with a Bearer header. Whether the MSG stream uses Anthropic's event names is implied (it is an Anthropic-compatible API for Claude Code and `message_delta` is named as carrying final usage) [doc: inference page "Cost"] but not spelled out [partly unverified].
- Model-routing consequences for a CC-only provider: Claude and GPT are NOT reachable on `/chat/completions`. On OpenCode, Kimi, GLM, DeepSeek, MiniMax are. Qwen: CC only for `qwen3.8-max` on pay-go.

### Model ids and models list
- Plain ids, no vendor prefix. Claude uses **hyphens for versions**: `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-haiku-5-5`, `claude-fable-5-1`. Others use dots: `gpt-5.6-luna`, `gpt-6.1-sol`, `kimi-k3`, `kimi-k2.7-code`, `glm-5.3`, `qwen3.8-max`, `deepseek-v4-pro`, `deepseek-v4.1-flash`, `minimax-m3` [doc: models page tables; ids confirmed present in the live list].
- Models list: `GET https://opencode.ai/inference/v1/models` (pay-go, 85 entries) and `GET https://opencode.ai/inference/go/v1/models` (Go, 38 entries). The docs' models-page example is `curl https://opencode.ai/inference/v1/models` with no auth header; the API-overview example sends a Bearer key. I fetched both unauthenticated: HTTP 200 [measured].
- Size [measured]: pay-go **7,091 bytes**; Go **3,159 bytes**. Gzip is ~578 bytes for pay-go. `cache-control: no-store`. Entry is tiny: `{"id","object":"model","created","owned_by":"opencode"}`. No capability, family, or pricing metadata.
- Caveat: the list includes ids not in the docs table (`test`, `omen-alpha`, `claude-opus-5-5-backup`, `iceman-contributor-free`) [measured]. Also, an unauthenticated list can't show which models your workspace has enabled (workspace owners choose enabled models) [doc: models page "For teams"].

### CC streaming
- OpenAI-compatible Chat Completions. Docs state `stream_options.include_usage` yields the final usage chunk [doc: inference page "Cost"]. Mentioned only for cost; SSE framing, `[DONE]`, keep-alive comments, reasoning field names, mid-stream error format and finish_reason set are **not documented** on OpenCode [doc silent; unverified]. Models are proxied from upstream (e.g. Kimi/GLM/DeepSeek), so expect `reasoning_content` (DeepSeek/Kimi/GLM native convention) and/or `reasoning` [unverified guess; handle both].
- Usage carries extra fields: `usage.cost` (USD charged), `usage.opencode.{billing_source,list_cost,tokens{input,output,reasoning,cache_read,cache_write_5m,cache_write_1h},allowance}` [doc: inference page].
- Reasoning-effort request field: not documented [unverified]. The OpenCode CLI maps its own variants; nothing in the console API docs.

### Errors
- Insufficient credits: HTTP **402**, body text `Upstream request failed: Insufficient account funds` [doc: https://opencode.ai/v2/docs/console/billing/]. The JSON envelope around it isn't shown [unverified].
- Budget reached: HTTP **429**, message `Upstream request failed: Policy budget exceeded` [doc: https://opencode.ai/v2/docs/console/budgets/].
- 401 for revoked/expired keys; 403 for out-of-permission requests and for free-tier models used outside OpenCode [doc: console/api and inference pages].
- JSON error shape is not documented [unverified]; parse defensively (look for `error.message`, else raw body).

### Prompt caching
- Pricing tables list "Cached Read" and "Cached Write" per model; Claude cached-write at 1.25x [doc: models page pricing]. For Claude on the MSG path `cache_control` should be passed through to Anthropic as with the native API [unverified: the docs don't say so explicitly]. For CC/open models caching is provider-side/implicit [unverified]. Go asks clients to send `x-opencode-session` (stable per conversation) "so we can optimize routing and prompt caching" [doc: Go page].
- Responses report `cache_read`/`cache_write_*` token counts in `usage.opencode.tokens`.

### Things that could break a minimal client
- Wrong path for a model silently fails (model not served on that API): needs a model->family table.
- Free models 403 in third-party clients.
- Go policy: must look like a coding agent; send own User-Agent and `x-opencode-session`.
- Claude/Qwen on MSG need `max_tokens`.
- Hyphenated Claude ids (`claude-sonnet-5-5`), unlike Anthropic's own and the gateways' dotted ids.
- Documented error text is plain strings; no documented JSON schema.

---------------------------------------------------------------------------------------------------

## 4. Comparison table

| Item | OpenRouter | Vercel AI Gateway | OpenCode Console (pay-go) / Go |
|---|---|---|---|
| Base | `https://openrouter.ai/api/v1` | `https://ai-gateway.vercel.sh/v1` (MSG base `https://ai-gateway.vercel.sh`) | `https://opencode.ai/inference/<family>/...` / `https://opencode.ai/inference/go/<family>/...` |
| Auth | `Authorization: Bearer` | `Authorization: Bearer` (`x-api-key` also OK on MSG) | `Authorization: Bearer` |
| Key prefix | `sk-or-v1-` | `vck_` (one doc mention) | `oc_sk_` |
| Required extra headers | none (HTTP-Referer, X-OpenRouter-Title/X-Title optional) | none | none for pay-go; Go wants own UA + `x-opencode-session` |
| CC path / which models | `/chat/completions` / all | `/chat/completions` / all | `/openai/v1/chat/completions` / open models only |
| RESP path | `/responses` / all | `/responses` / all | `/openai/v1/responses` / GPT, Grok, Muse |
| MSG path | `/messages` / all | `/v1/messages` / all | `/anthropic/v1/messages` / Claude + most Qwen |
| Model id style | `author/slug` (`anthropic/claude-sonnet-5.5`, `z-ai/glm-5.3`, `qwen/...`) | `provider/slug` (`anthropic/claude-sonnet-5.5`, `zai/glm-5.3`, `alibaba/...`) | bare (`claude-sonnet-5-5`, `glm-5.3`, `kimi-k3`) |
| Models list | `GET /api/v1/models` no auth, 791 KB (81 KB gz), filter/limit supported | `GET /v1/models` no auth, 544 KB (64 KB gz), no filters documented | `GET /inference/v1/models` no auth, 7 KB (Go: 3 KB), ids only |
| `[DONE]` | yes | yes | not documented |
| Keep-alive comments | `: OPENROUTER PROCESSING` | not documented | not documented |
| Stream usage | automatic final chunk (non-empty `choices`, dup finish_reason) | undocumented (send `include_usage`) | `stream_options.include_usage` (documented) |
| Reasoning delta | `delta.reasoning` + `delta.reasoning_details` (`reasoning_content` input alias) | `delta.reasoning` + `delta.reasoning_details` | undocumented (guess `reasoning_content`/`reasoning`) |
| Effort request | `reasoning:{effort}` or `{max_tokens}` | `reasoning:{effort}` or `reasoning_effort` | undocumented |
| Mid-stream error | top-level `error` + `finish_reason:"error"`, HTTP 200 | undocumented | undocumented |
| Error body | `{"error":{"code":int,"message","metadata"}}` | `{"error":{"message","type","param","code"}}` | plain message text; JSON shape undocumented |
| 402 | insufficient credits | budget exceeded (`quota_for_entity_exceeded`) | insufficient funds |
| 429 | rate limit; Retry-After | rate limit (free tier) | policy budget exceeded |
| Claude caching | `cache_control` on blocks or top-level, CC/MSG; auto-top-level also RESP | `cache_control` on message (CC), `caching:'auto'`, pass-through on MSG | undocumented; MSG presumed pass-through |
| MSG events same as Anthropic | yes (OpenAPI event union; usage in `message_delta`) | yes (documented event list) | implied, not spelled out |
| MSG `max_tokens` required | schema says no | yes | yes |

---------------------------------------------------------------------------------------------------

## 5. What a single OpenAI-compatible Chat Completions provider with per-service presets would need

Preset fields (per service):
1. `base_url` and CC path: OR `https://openrouter.ai/api/v1/chat/completions`; Vercel `https://ai-gateway.vercel.sh/v1/chat/completions`; OpenCode `https://opencode.ai/inference/openai/v1/chat/completions` (Go: `.../inference/go/openai/v1/chat/completions`).
2. Auth: all `Authorization: Bearer <key>`. Key sanity check: `sk-or-v1-`, `vck_`, `oc_sk_` (warn, don't block).
3. Extra headers: OR optional `HTTP-Referer` + `X-OpenRouter-Title`; Vercel none; OpenCode none (Go: custom `User-Agent`, `x-opencode-session`).
4. Model id scheme + a curated model list: the app should ship its own short list per preset; never download OR (791 KB) or Vercel (544 KB) lists on-device. OpenCode's 7 KB list is OK to fetch but lacks family info. If a dynamic list is wanted for OR, use `?limit=20&q=...&output_modalities=text` (~1.5 KB/model).
5. Model-family gating (OpenCode only): CC only serves open models; Claude/GPT/Gemini need other APIs. For OpenCode, restrict the CC preset to the CC-family ids (Kimi, GLM, DeepSeek, MiniMax, Mistral, qwen3.8-max), or route Claude/Qwen through the existing Anthropic provider (base `https://opencode.ai/inference/anthropic`, Bearer auth, `max_tokens` required) and GPT through the existing Responses provider (`https://opencode.ai/inference/openai/v1/responses`). Same idea is available but optional on OR (`/api` base for MSG) and Vercel.
6. Stream parsing tweaks:
   - Skip lines starting with `:` (OR sends `: OPENROUTER PROCESSING`; harmless elsewhere).
   - Handle `data: [DONE]` (OR, Vercel documented; OpenCode undocumented, so also end on EOF).
   - Tolerate `delta.content` null/empty and a usage-only final chunk (OR's has one choice with an empty delta and duplicate `finish_reason`; OpenAI-style has empty `choices`; guard `choices[1]` nil).
   - Mid-stream error: check each chunk for top-level `error` (OR) and `finish_reason == "error"`; HTTP status will be 200.
7. Usage: send `stream_options={include_usage=true}` everywhere (needed for OpenCode, probably needed for Vercel, harmless on OR). Read `usage.prompt_tokens/completion_tokens`, `prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens`, plus optional `usage.cost` (OR and OpenCode).
8. Reasoning: read `delta.reasoning`, fall back to `delta.reasoning_content` (OpenCode/DeepSeek/Kimi/GLM native), ignore `reasoning_details`. Request knob: OR `reasoning={effort=...}`; Vercel `reasoning={effort=...}` or `reasoning_effort`; OpenCode unknown, so default to omit and allow a user-supplied extra-body field. Warn that reasoning shares `max_tokens` (empty content with `finish_reason=length`).
9. Prompt caching for Claude on the CC path (the 16 KB system prompt):
   - OR: either add top-level `cache_control={type="ephemeral"}` to the body, or send `system` as a content-block array with `cache_control` on the block.
   - Vercel: add `cache_control` on the system message object, or `caching="auto"` (docs place it in `providerOptions.gateway`).
   - OpenCode: Claude isn't on CC; use the Anthropic provider path (native `cache_control` assumed passthrough, unverified).
   - OpenAI/DeepSeek/Gemini/Kimi/GLM: automatic, no change.
   - Optionally send a stable `x-session-id` (OR, Vercel) / `x-opencode-session` (OpenCode) to improve cache hits.
10. Error decoding: three shapes. OR `error.code` int + `error.message` (+ `metadata`); Vercel/OpenAI-style `error.message/type/code`; OpenCode plain text like `Upstream request failed: Insufficient account funds`. A generic decoder: try JSON `error.message`, else show the raw body (truncate for RAM). Map status: 401 bad key; 402 out of credits/budget (OR Retry-After only in a narrow case); 403 (OR: guardrail/budget; OpenCode: free model outside OpenCode); 429 back off; 5xx retry once.
11. Title request (non-streaming, cheap model): per preset default e.g. OR `anthropic/claude-haiku-5.5` (or `~anthropic/claude-haiku-latest`), Vercel `anthropic/claude-haiku-5.5`, OpenCode `claude-haiku-5-5` (MSG path only, so on the CC preset use `glm-5.3-flash` or `deepseek-v4.1-flash`). Non-streaming CC works the same everywhere; set a small `max_tokens`.
12. Idle timeout: OR sends keep-alive comments (interval undocumented); Vercel and OpenCode document nothing, so for reasoning models allow a longer first-byte timeout on those presets [unverified recommendation].

Open items that need one real authenticated call to settle: Vercel stream usage chunk and keep-alive, Vercel/OpenCode mid-stream error shape, OpenCode reasoning delta field name and effort parameter, OpenCode JSON error shape, OpenCode Claude `cache_control` pass-through, whether OpenRouter's `reasoning_effort` top-level works on CC.

## Measured 2026-10-26 (controller probes, one streaming CC request each; raw in docs/research/gateway-probes/)

- OpenRouter: the owner's key is EXPIRED (401 `{"error":{"message":"API key expired.","code":401,"metadata":{...}}}`). A missing or bad key gives 401 `{"error":{"message":"Missing Authentication header","code":401}}`.
- Vercel, deepseek/deepseek-v4.1-flash-1017:
  - HTTP 200 `text/event-stream`, first byte 1.26 s, longest gap 0.42 s. 48 data lines, then `data: [DONE]`; no comment lines.
  - Each delta carries `reasoning` and `reasoning_details` (`[{type:"reasoning.text",text,format,index}]`), then `content`, then `provider_metadata`.
  - Usage arrives in the LAST chunk, which also has a non-empty `choices` (a delta with `provider_metadata`). It includes `cost`, `is_byok:true` (the owner's Vercel account routes DeepSeek through their own provider key), `cost_details.upstream_inference_cost`, `prompt_tokens_details.cached_tokens` and `completion_tokens_details.reasoning_tokens`.
  - Chunks carry a top-level `generationId`. A bad key gives 401 `{"error":{"message":"Authentication failed. ...","type":"authentication_error"}}`.
- OpenCode, deepseek-v4.1-flash at /inference/openai/v1/chat/completions, `reasoning_effort:"low"` accepted:
  - HTTP 200, first byte 0.88 s. 24 data lines, then `[DONE]`; no comments.
  - Reasoning is in `delta.reasoning_content`.
  - Usage arrives in a chunk with EMPTY `choices`. It includes `cost`, `cache_read_input_tokens` and an `opencode` object (billing_source, list_cost, tokens{...}).
  - A bad key gives 401 `{"error":{"type":"server_error","message":"Upstream request failed: Invalid credential"}}`. Note that the type is server_error, so the status code must decide it, not the type.
- No `<think>` tags in content for DeepSeek on either. MiniMax and Gemini are unprobed: the OpenRouter key expired, and they could be probed on Vercel next.
- Vercel, minimax/minimax-m3.1-flash: 200, first byte 0.54 s. Reasoning in `reasoning` + `reasoning_details`, and no `<think>` in content. prompt_tokens 208 with 184 cached (MiniMax adds its own preamble). cost $0.000034, is_byok false.
- Vercel, google/gemini-3.8-flash: 200, first byte 2.29 s. Only `reasoning_details` (no plain `reasoning` text), reasoning_tokens 0 at effort low. cost $0.000116.
- Probe spend in total, Claude recordings included: about $0.0025 (docs/research/api-spend.md on branch chore/real-claude-fixtures).
