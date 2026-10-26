local T = require("tests.t")
local S = require("src.services")

return {
    table_matches_spec = function()
        T.same(S.ORDER, { "anthropic", "opencode", "openrouter", "vercel" })
        T.same(S.BY_ID.anthropic, {
            id = "anthropic", label = "Anthropic", color = { 217, 119, 87 },
            base = "https://api.anthropic.com", chatPath = "/v1/messages", effort = "output_config",
        })
        T.same(S.BY_ID.opencode, {
            id = "opencode", label = "OpenCode", color = { 240, 196, 70 },
            base = "https://opencode.ai", chatPath = "/inference/openai/v1/chat/completions",
            listPath = "/inference/v1/models", effort = "reasoning_effort",
        })
        T.same(S.BY_ID.openrouter, {
            id = "openrouter", label = "OpenRouter", color = { 120, 140, 255 },
            base = "https://openrouter.ai", chatPath = "/api/v1/chat/completions",
            listPath = "/api/v1/models?output_modalities=text", effort = "reasoning",
        })
        T.same(S.BY_ID.vercel, {
            id = "vercel", label = "Vercel", color = { 215, 215, 215 },
            base = "https://ai-gateway.vercel.sh", chatPath = "/v1/chat/completions",
            listPath = "/v1/models", effort = "reasoning",
        })
        T.eq(S.DEFAULT_MODEL, "anthropic/claude-opus-5-5")
    end,

    split_and_valid = function()
        local s, r = S.split("openrouter/deepseek/deepseek-v4.1-flash-1017")
        T.eq(s, "openrouter"); T.eq(r, "deepseek/deepseek-v4.1-flash-1017")
        s, r = S.split("opencode/deepseek-v4.1-flash")
        T.eq(s, "opencode"); T.eq(r, "deepseek-v4.1-flash")
        s, r = S.split("openrouter/~deepseek/deepseek-flash-latest")
        T.eq(s, "openrouter"); T.eq(r, "~deepseek/deepseek-flash-latest")
        T.ok(S.valid("vercel/google/gemini-3.8-flash"))
        T.ok(S.valid("openrouter/qwen/qwen3.8-max:free"))
        local id120 = "vercel/" .. string.rep("a", 113)
        T.eq(#id120, 120); T.ok(S.valid(id120))
        for _, bad in ipairs({ "openrouter/", "foo/bar", "anthropic", "vercel/a b", "Vercel/x",
            "vercel/x/", "vercel//x", "vercel/" .. string.rep("a", 114), "", " vercel/x" }) do
            T.eq(S.split(bad), nil, "split " .. bad)
            T.eq(S.valid(bad), false, "valid " .. bad)
        end
        T.eq(S.split(nil), nil); T.eq(S.valid(5), false)
    end,

    short = function()
        T.eq(S.short("vercel/google/gemini-3.8-flash"), "gemini-3.8-flash")
        T.eq(S.short("anthropic/claude-opus-5-5"), "claude-opus-5-5")
        T.eq(S.short("claude-opus-5-5"), "claude-opus-5-5")
    end,

    full_old_items = function()
        T.eq(S.full("claude", "claude-opus-5-5"), "anthropic/claude-opus-5-5")
        T.eq(S.full("anthropic", "claude-haiku-5-5"), "anthropic/claude-haiku-5-5")
        T.eq(S.full("openai", "gpt-6-luna"), "openai/gpt-6-luna")
        T.eq(S.full("vercel", "vercel/google/gemini-3.8-flash"), "vercel/google/gemini-3.8-flash")
        T.eq(S.full("anthropic", "anthropic/claude-opus-5-5"), "anthropic/claude-opus-5-5")
        T.eq(S.full("claude", nil), nil)
    end,

    labels_and_colors = function()
        T.eq(S.of("claude"), "anthropic")
        for _, id in ipairs(S.ORDER) do T.eq(S.of(id), id) end
        T.eq(S.of("openai"), "openai"); T.eq(S.of("zzz"), "zzz")
        T.eq(S.label("anthropic"), "Anthropic"); T.eq(S.label("claude"), "Anthropic")
        T.eq(S.label("opencode"), "OpenCode"); T.eq(S.label("openrouter"), "OpenRouter")
        T.eq(S.label("vercel"), "Vercel"); T.eq(S.label("openai"), "OpenAI")
        T.eq(S.label("zzz"), "zzz")
        T.same(S.color("anthropic"), { 217, 119, 87 }); T.same(S.color("claude"), { 217, 119, 87 })
        T.same(S.color("opencode"), { 240, 196, 70 }); T.same(S.color("openrouter"), { 120, 140, 255 })
        T.same(S.color("vercel"), { 215, 215, 215 }); T.same(S.color("openai"), { 16, 163, 127 })
        T.same(S.color("zzz"), { 130, 130, 130 })
    end,
}
