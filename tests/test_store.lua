local T = require("tests.t")
local fakes = require("tests.fakes")
local Fake = require("tests.fakepc")
local json = require("tests.json")
local Store = require("src.store")
local Programs = require("src.programs")

local D = "/data/net.picodeck.llmchat"

local function mk()
    local fs, files = fakes.fs()
    return Store.new(fs, json, D), fs, files
end

local function chat(id, updated)
    return { v = 1, id = id, title = "T" .. id, created = updated, updated = updated,
             items = { { role = "user", text = "hi" } } }
end

-- S1: a Store on the fake firmware (F.slowMode, F.slowWrites), with its
-- radioBusy check answering `busy`, and every call that changes the card
-- recorded with whether the bus was in slow mode at the time.
local CHANGES = { "open", "write", "close", "delete", "deleteRecursive", "rename", "mkdir" }
local function onCard(busy)
    local F = Fake.new()
    local seen = {}
    for _, name in ipairs(CHANGES) do
        local f = F.pc.fs[name]
        F.pc.fs[name] = function(...)
            seen[#seen + 1] = { call = name, slow = F.slowMode }
            return f(...)
        end
    end
    local s = Store.new(F.pc.fs, json, D)
    s.radioBusy = function() return busy end
    return s, F, seen
end

-- Every way the app changes the card: prefs, keys, chats and the index
-- (with the cap's deletes), a chat's delete, a corrupt file set aside, a
-- save cut before its rename finished on read, the old key's import, and
-- programs (saved over with .prev, adopted, orphaned, deleted with data).
local function everyWrite(s, F)
    s:savePrefs()
    s:setKey("claude", "sk-ant-test")
    for i = 1, Store.CAP + 1 do assert(s:saveChat(chat("c" .. i, i))) end
    assert(s:deleteChat("c51"))
    F.files[D .. "/chats/bad.json"] = "{not json"
    s:loadChat("bad")
    F.files[D .. "/notes.txt.tmp"] = "cut"
    assert(s:readText("notes.txt") == "cut")
    local cfg = { llmchat_provider = "1", llmchat_api_key = "sk-old" }
    s:importOld({ get = function(k) return cfg[k] end, set = function(k, v) cfg[k] = v end,
                  save = function() F.pc.fs.mkdir(D .. "/config"); return true end })
    local progs = Programs.new(s)
    assert(progs:save("c2", { { name = "dice.lua", code = "-- dice.lua\n" } })[1] == "dice.lua")
    assert(progs:save("c2", { { name = "dice.lua", code = "-- dice.lua\nx = 1\n" } })[1] == "dice.lua")
    assert(progs:adopt("dice.lua", "c3"))
    assert(progs:orphan("c3"))
    F.files[progs:dataDir("dice.lua") .. "/save.json"] = "{}"
    progs:delete("dice.lua")
end

return {
    safe_save_replaces_existing = function()
        local s, fs, files = mk()
        T.ok(s:writeJSON("a.json", { n = 1 }))
        T.ok(s:writeJSON("a.json", { n = 2 }))
        T.eq(s:readJSON("a.json").n, 2)
        T.ok(not fs.exists(D .. "/a.json.tmp"), "tmp left behind")
    end,
    recovers_tmp_after_cut = function()
        local s, fs, files = mk()
        files[D .. "/prefs.json.tmp"] = '{"font":"mono"}'
        T.eq(s:readJSON("prefs.json").font, "mono")
        T.ok(fs.exists(D .. "/prefs.json"))
        T.ok(not fs.exists(D .. "/prefs.json.tmp"))
    end,
    corrupt_file_set_aside = function()
        local s, fs, files = mk()
        files[D .. "/chats/index.json"] = "{not json"
        T.same(s:chats(), {})
        T.ok(fs.exists(D .. "/chats/index.json.bad"))
        T.ok(not fs.exists(D .. "/chats/index.json"))
    end,
    corrupt_prefs_and_chat_do_not_crash = function()
        local s, fs, files = mk()
        files[D .. "/prefs.json"] = "\0\1garbage"
        files[D .. "/chats/x1.json"] = '{"items": 5}'
        T.eq(s:prefs().provider, "claude")
        T.eq(s:loadChat("x1"), nil)
        T.eq(s:loadChat("../evil"), nil)
    end,
    failed_write_keeps_old = function()
        local s, fs = mk()
        T.ok(s:writeJSON("a.json", { n = 1 }))
        fs.failWrite = true
        local ok, err = s:writeJSON("a.json", { n = 2 })
        T.eq(ok, nil)
        T.ok(err)
        fs.failWrite = nil
        T.eq(s:readJSON("a.json").n, 1)
        T.ok(not fs.exists(D .. "/a.json.tmp"))
    end,
    short_close_keeps_old = function()
        local s, fs = mk()
        T.ok(s:writeJSON("a.json", { n = 1 }))
        fs.shortClose = true
        T.eq((s:writeJSON("a.json", { n = 2 })), nil)
        fs.shortClose = nil
        T.eq(s:readJSON("a.json").n, 1)
    end,
    failed_rename_recovers_on_read = function()
        local s, fs = mk()
        T.ok(s:writeJSON("a.json", { n = 1 }))
        fs.failRename = true
        T.eq((s:writeJSON("a.json", { n = 2 })), nil)
        fs.failRename = nil
        T.eq(s:readJSON("a.json").n, 2)
    end,
    unreadable_is_not_corrupt = function()
        local s, fs = mk()
        T.ok(s:writeJSON("a.json", { n = 1 }))
        fs.failRead = true
        T.eq(s:readJSON("a.json"), nil)
        fs.failRead = nil
        T.eq(s:readJSON("a.json").n, 1)
    end,
    prefs_defaults = function()
        local s = mk()
        local p = s:prefs()
        T.eq(p.provider, "claude")
        T.eq(p.models.claude, "claude-opus-5-5")
        T.eq(p.models.openai, "gpt-6-luna")
        T.eq(p.thinking, "low")
        T.eq(p.font, "sans")
        T.eq(p.instructions, "Keep answers short: I'm reading on a 320 px screen.")
    end,
    prefs_save_and_reload = function()
        local s, fs = mk()
        local p = s:prefs()
        p.font = "mono"; p.models.openai = "gpt-x"; p.drafts = { c1 = "hello" }
        T.ok(s:savePrefs())
        local s2 = Store.new(fs, json, D)
        T.eq(s2:prefs().font, "mono")
        T.eq(s2:prefs().models.openai, "gpt-x")
        T.eq(s2:prefs().models.claude, "claude-opus-5-5")
        T.eq(s2:prefs().drafts.c1, "hello")
        s2:prefs().drafts = {}
        T.ok(s2:savePrefs())
    end,
    base_override_loopback_only = function()
        local s = mk()
        local p = s:prefs()
        p.claude_base = "http://127.0.0.1:9000"
        p.openai_base = "http://localhost:9000"
        T.eq(s:base("claude"), "http://127.0.0.1:9000")
        T.eq(s:base("openai"), "http://localhost:9000")
        for _, bad in ipairs({ "http://evil.example:9000", "https://127.0.0.1:9000",
                               "http://127.0.0.1", "http://127.0.0.1:9000/x", "http://127.0.0.1:9000@evil.com" }) do
            p.claude_base = bad
            T.eq(s:base("claude"), nil, bad)
        end
        p.claude_base = 5
        T.eq(s:base("claude"), nil)
    end,
    keys_parse = function()
        local s, fs, files = mk()
        files[D .. "/keys.txt"] = "# c\nclaude = sk-ant-x \nopenai=sk-y\n"
        T.same(s:keys(), { claude = "sk-ant-x", openai = "sk-y" })
        T.ok(s:setKey("openai", "sk-new"))
        local s2 = Store.new(fs, json, D)
        T.same(s2:keys(), { claude = "sk-ant-x", openai = "sk-new" })
        T.ok(files[D .. "/keys.txt"]:sub(1, 1) == "#")
    end,
    keys_missing_file = function()
        local s = mk()
        T.same(s:keys(), {})
    end,
    import_old = function()
        local s = mk()
        local cfg = { llmchat_provider = "2", llmchat_api_key = "sk-ant-old" }
        local saved = false
        local config = {
            get = function(k) return cfg[k] end,
            set = function(k, v) cfg[k] = v end,
            save = function() saved = true; return true end,
        }
        T.eq(s:importOld(config), true)
        T.eq(s:keys().claude, "sk-ant-old")
        T.eq(cfg.llmchat_api_key, nil)
        T.eq(cfg.llmchat_provider, nil)
        T.ok(saved)
        T.eq(s:importOld(config), false)
    end,
    import_old_openai_and_ollama = function()
        local s = mk()
        local cfg = { llmchat_provider = "1", llmchat_api_key = "sk-o" }
        local config = { get = function(k) return cfg[k] end, set = function(k, v) cfg[k] = v end,
                         save = function() return true end }
        T.eq(s:importOld(config), true)
        T.eq(s:keys().openai, "sk-o")
        local s2 = mk()
        cfg = { llmchat_provider = "3", llmchat_api_key = "x" }
        T.eq(s2:importOld(config), false)
        T.same(s2:keys(), {})
        T.eq(cfg.llmchat_api_key, nil)
        T.eq(cfg.llmchat_provider, nil)
        T.eq(s2:importOld(config), false)
    end,
    keys_recovered_from_tmp = function()
        local s, fs, files = mk()
        files[D .. "/keys.txt.tmp"] = "claude=a\nopenai=b\n"
        T.same(s:keys(), { claude = "a", openai = "b" })
        T.ok(fs.exists(D .. "/keys.txt"))
        T.ok(not fs.exists(D .. "/keys.txt.tmp"))
    end,
    import_aborts_without_clearing_when_write_fails = function()
        local s, fs = mk()
        local cfg = { llmchat_provider = "2", llmchat_api_key = "k" }
        local config = { get = function(k) return cfg[k] end, set = function(k, v) cfg[k] = v end,
                         save = function() return true end }
        fs.failWrite = true
        T.eq(s:importOld(config), false)
        T.eq(cfg.llmchat_api_key, "k")
    end,
    cap_50_keeps_newest = function()
        local s, fs = mk()
        local removed
        for i = 1, 51 do
            local ok, r = s:saveChat(chat("c" .. i, 1000 + i))
            T.ok(ok)
            removed = r
        end
        T.eq(#removed, 1)
        T.eq(removed[1], "c1")
        T.eq(#s:chats(), 50)
        T.eq(s:chats()[1].id, "c51")
        T.eq(s:chats()[50].id, "c2")
        T.eq(s:loadChat("c1"), nil)
        T.ok(s:loadChat("c2"))
    end,
    save_returns_empty_removed_list = function()
        local s = mk()
        local ok, r = s:saveChat(chat("a", 5))
        T.eq(ok, true)
        T.same(r, {})
        local row = s:chats()[1]
        T.eq(row.count, 1)
        T.eq(row.title, "Ta")
    end,
    save_updates_row_and_delete = function()
        local s, fs = mk()
        s:saveChat(chat("a", 5)); s:saveChat(chat("b", 6))
        local c = chat("a", 9); c.title = "New"
        s:saveChat(c)
        T.eq(#s:chats(), 2)
        T.eq(s:chats()[1].id, "a")
        T.eq(s:chats()[1].title, "New")
        s:deleteChat("a")
        T.eq(#s:chats(), 1)
        T.eq(s:loadChat("a"), nil)
        s:deleteChat("b")
        T.same(s:chats(), {})
        local s2 = Store.new(fs, json, D)
        T.same(s2:chats(), {})
    end,
    failed_chat_write_returns_error = function()
        local s, fs = mk()
        fs.failWrite = true
        local ok, err = s:saveChat(chat("a", 5))
        T.eq(ok, nil)
        T.ok(err)
        T.same(s:chats(), {})
    end,
    new_id_unsynced = function()
        local s, fs = mk()
        local clock = { synced = false }
        T.eq(s:newId(clock), "c1")
        T.eq(s:newId(clock), "c2")
        T.eq(Store.new(fs, json, D):prefs().nextId, 2)
    end,
    new_id_synced = function()
        local s = mk()
        local id = s:newId({ synced = true, year = 2026, month = 10, day = 25,
                             hour = 14, min = 2, sec = 12, epoch = 1792936932 })
        T.eq(id, "20261025-140212-1")
    end,

    -- S1: while a request is in flight, the radio's EMI corrupts SD writes at
    -- full speed (picodeck sdcard.h), so every change the app makes to the
    -- card (the writes, and the deletes and renames that write the FAT and
    -- directory) runs with the bus in slow mode, which is off again after.
    every_write_slow_while_a_request_is_in_flight = function()
        local s, F, seen = onCard(true)
        everyWrite(s, F)
        T.ok(#seen > 100, "only " .. #seen .. " changes recorded")
        local kinds = {}
        for _, c in ipairs(seen) do
            kinds[c.call] = true
            T.ok(c.slow, c.call .. " at full speed with a request in flight")
        end
        for _, k in ipairs(CHANGES) do T.ok(kinds[k], "never seen: " .. k) end
        T.ok(F.slowWrites > 0)
        T.eq(F.slowMode, false, "left in slow mode")
    end,

    -- With nothing in flight the bus is left at full speed.
    writes_full_speed_with_nothing_in_flight = function()
        local s, F, seen = onCard(false)
        everyWrite(s, F)
        for _, c in ipairs(seen) do T.ok(not c.slow, c.call .. " in slow mode") end
        T.eq(F.slowWrites, 0)
        local plain = Store.new(F.pc.fs, json, D) -- no radioBusy check: never busy
        T.ok(plain:writeText("x.txt", "x"))
        T.eq(F.slowWrites, 0)
    end,

    -- Slow mode is off again after a write that fails or raises, and the
    -- error goes on as it was.
    slow_mode_off_after_a_failed_write = function()
        local s, F = onCard(true)
        F.pc.fs.failOpen = true
        T.eq(s:writeText("a.txt", "x"), nil)
        T.eq(F.slowMode, false, "after a failed open")
        F.pc.fs.failOpen = false
        F.pc.fs.failWrite = true
        T.eq(s:writeText("a.txt", "x"), nil)
        T.eq(F.slowMode, false, "after a failed write")
        F.pc.fs.failWrite = false
        F.pc.fs.rename = function() error("not enough memory", 0) end
        local ok, err = pcall(s.writeText, s, "a.txt", "x")
        T.eq(ok, false)
        T.eq(err, "not enough memory")
        T.eq(F.slowMode, false, "after a write that raised")
        local exit = {} -- the firmware's exit is not a string
        F.pc.fs.open = function() error(exit) end
        ok, err = pcall(s.savePrefs, s)
        T.ok(rawequal(err, exit), "the error changed on the way")
        T.eq(F.slowMode, false, "after an open that raised")
    end,
}
