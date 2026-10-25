-- The chat controller (spec 6, 8): owns the open conversation, sends a
-- request, drives the stream every frame, saves, adds notes and asks for a
-- tidy title. No drawing here.
local Http = require("src.http")
local SSE = require("src.sse")
local Titles = require("src.titles")
local Programs = require("src.programs")

local Chat = {}
Chat.__index = Chat

Chat.LONG_BYTES = 150 * 1024 -- provisional (ruling R16)
Chat.CLOCK_RETRY_MS = 3000

local LONG_NOTE = "This chat is getting long; F2 starts a new one."
local LOST_NOTE = "Connection lost; the reply is incomplete."

function Chat.new(deps)
    local self = setmetatable({ deps = deps }, Chat)
    self.version = 0
    self.removed = {} -- ids of chats the store dropped (cap); Task 13 drains this
    self:open(nil)
    return self
end

function Chat:_bump() self.version = self.version + 1 end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function Chat:provider()
    local prefs = self.deps.store:prefs()
    return self.deps.providers[prefs.provider] or self.deps.providers.claude
end

function Chat:_abort()
    if self.req then self.req:cancel() end
    if self.titleReq then self.titleReq:cancel() end
    self.req, self.titleReq, self.sse, self.parserFeed = nil, nil, nil, nil
    self.retryAt, self.doneInfo, self.errMsg, self.errBody = nil, nil, nil, nil
    self.titling = false
end

-- id: open that saved chat (false when it can't be read); nil: a fresh chat.
function Chat:open(id)
    self:_abort()
    self.state, self.live = "idle", nil
    self.lastProgramName = nil
    if id == nil then
        self.id, self.title, self.items = nil, "", {}
        self.created, self.updated, self.model, self.providerId = nil, nil, nil, nil
        self.programs, self.lastProgramName, self.clockRetried = nil, nil, false
        self.titlePending, self.longNoted = true, false
        self:_bump()
        return true
    end
    local c = self.deps.store:loadChat(id)
    if not c then return false end
    self.id, self.title, self.items = c.id or id, c.title or "", c.items
    self.created, self.updated = c.created, c.updated
    self.model, self.providerId = c.model, c.provider
    self.programs = c.programs
    self.titlePending = false
    self.longNoted = false
    for _, it in ipairs(self.items) do
        if it.role == "note" and it.text == LONG_NOTE then self.longNoted = true end
    end
    self:_bump()
    return true
end

-- ------------------------------------------------------------------ saving

function Chat:_clock()
    local ok, c = pcall(self.deps.pc.sys.getClock)
    if ok and type(c) == "table" then return c end
    return { synced = false }
end

local function hasConversation(items)
    for _, it in ipairs(items) do
        if it.role == "user" or it.role == "assistant" then return true end
    end
    return false
end

-- Writes the chat file and index row. true | nil, err. A chat with no user or
-- assistant item yet (only notes) is not saved.
function Chat:_save()
    if not hasConversation(self.items) then return true end
    local store, clock = self.deps.store, self:_clock()
    if not self.id then self.id = store:newId(clock) end
    local now = clock.synced and clock.epoch or nil
    if now then
        self.created = self.created or now
        self.updated = now
    else
        self.created = self.created or 0
        self.updated = (self.updated or 0) + 1
    end
    local out = {
        v = 1, id = self.id, title = self.title, created = self.created, updated = self.updated,
        provider = self.providerId, model = self.model, items = self.items,
    }
    if self.programs and next(self.programs) ~= nil then out.programs = self.programs end
    local ok, removed = store:saveChat(out)
    if not ok then return nil, removed end
    for _, rid in ipairs(removed or {}) do self.removed[#self.removed + 1] = rid end
    local progs = self.deps.programs
    if progs then -- ruling R4: programs of chats the cap dropped lose their owner
        for _, rid in ipairs(self.removed) do progs:orphan(rid) end
        self.removed = {}
    end
    return true
end

local function lastIsSaveNote(items)
    local last = items[#items]
    return last and last.role == "note" and last.text:find("Couldn't save: ", 1, true) == 1
end

-- Save; on failure show a note (itself unsaved). The reply stays on screen.
function Chat:_persist()
    local ok, err = self:_save()
    if not ok and not lastIsSaveNote(self.items) then
        self:_push("error", "Couldn't save: " .. tostring(err), true)
    end
    return ok
end

-- -------------------------------------------------------------------- notes

function Chat:_push(kind, text, isError)
    local it = { role = "note", kind = kind, text = text }
    if isError or kind == "error" then it.error = true end
    self.items[#self.items + 1] = it
    self:_bump()
end

-- kind: "error" | "info" | "program". Saved with the chat.
function Chat:note(kind, text, isError)
    self:_push(kind, text, isError)
    self:_persist()
end

-- The newest program saved from this chat's replies (F3's), or nil. A
-- reopened chat finds it in its replies' per-block names (item.programs).
function Chat:lastProgram()
    if self.lastProgramName then return self.lastProgramName end
    for i = #self.items, 1, -1 do
        local per = self.items[i].role == "assistant" and self.items[i].programs
        if type(per) == "table" then
            for j = #per, 1, -1 do
                if type(per[j]) == "string" then
                    self.lastProgramName = per[j]
                    return per[j]
                end
            end
        end
    end
    return nil
end

-- --------------------------------------------------------------- fixing

-- The message that asks for a fix (spec 9.6). result: Sandbox.execute's
-- ({err, printed}); the "It printed:" block only when it printed something.
function Chat.fixText(name, result)
    local lines = { name .. " stopped with an error:", result.err or "" }
    local printed = result.printed or {}
    if #printed > 0 then
        lines[#lines + 1] = "It printed:"
        for _, l in ipairs(printed) do lines[#lines + 1] = l end
    end
    lines[#lines + 1] = "Please send a fixed version of the whole program."
    return table.concat(lines, "\n")
end

-- Appends the fix request and sends it: true | false, why (as send). The code
-- is already in the conversation, so it isn't resent. With `code` (a program
-- whose chat was deleted; this is a new chat), the message starts with the
-- program in a lua fence, and this chat becomes the program's owner, so the
-- fixed version saves over the same file.
function Chat:askFix(name, result, code)
    local text = Chat.fixText(name, result)
    if code then
        if code:sub(-1) ~= "\n" then code = code .. "\n" end
        text = "```lua\n" .. code .. "```\n" .. text
        if self.title == "" then self.title = "Fix " .. name end
    end
    local ok, why = self:send(text)
    if not ok or not code then return ok, why end
    local progs = self.deps.programs
    if not self.id then self.id = self.deps.store:newId(self:_clock()) end
    if progs then
        local adopted, err = progs:adopt(name, self.id)
        if not adopted then self:_push("error", "Couldn't take over " .. name .. ": " .. tostring(err), true) end
    end
    self:_persist() -- the owner's chat is on the card before its reply
    return true
end

-- ------------------------------------------------------------------ sending

function Chat:_prefs() return self.deps.store:prefs() end

function Chat:_key(P)
    return self.deps.store:keys()[P.id]
end

function Chat:_online()
    local net = self.deps.pc.network
    return net.getStatus() == net.kStatusConnected
end

-- true | false, "empty" | "busy" | "nokey"
function Chat:send(text)
    text = trim(tostring(text or ""))
    if text == "" then return false, "empty" end
    if self.state ~= "idle" then return false, "busy" end
    local P = self:provider()
    if not self:_key(P) then
        self:note("error", "Add your " .. P.label .. " key in Settings (F5).", true)
        return false, "nokey"
    end
    if #self.items == 0 or not hasConversation(self.items) then
        if self.title == "" then self.title = Titles.fromMessage(text) end
    end
    self.items[#self.items + 1] = { role = "user", text = text }
    self:_bump()
    self:_start()
    return true
end

-- Sends again when the last thing in the chat is a user message with no reply.
function Chat:retry()
    if self.state ~= "idle" then return false end
    local last
    for i = #self.items, 1, -1 do
        if self.items[i].role ~= "note" then last = self.items[i] break end
    end
    if not last or last.role ~= "user" then return false end
    local P = self:provider()
    if not self:_key(P) then
        self:note("error", "Add your " .. P.label .. " key in Settings (F5).", true)
        return false
    end
    self:_start()
    return true
end

-- Builds and starts the request for the current items. Sets the state.
function Chat:_start()
    local P = self:provider()
    local prefs = self:_prefs()
    self.state, self.live = "waiting", { text = "" }
    self.reqProv = P
    self.model = prefs.models[P.id] or P.DEFAULT_MODEL
    self.providerId = P.id
    self.doneInfo, self.errMsg, self.errBody = nil, nil, nil
    self.clockRetried = false
    self:_bump()
    if not self:_online() then
        self:_finishFailed("No WiFi.")
        return
    end
    self:_launch()
end

function Chat:_launch()
    local deps, P = self.deps, self.reqProv
    local prefs = self:_prefs()
    local path, headers, body = P.request(deps.pc.json, self.items, {
        key = self:_key(P), model = self.model,
        effort = tostring(prefs.thinking or "low"):lower(),
        system = deps.prompt(),
    })
    local base = deps.store:base(P.id) or P.BASE
    self.req = Http.post(deps.pc.network, base, path, headers, body)
    self.gotText = false
    self.sse = SSE.new(function(name, data) self.parserFeed(name, data) end)
    self.parserFeed = P.parser(deps.pc.json, {
        text = function(s)
            self.live.text = self.live.text .. s
            self.state = "streaming"
            self:_bump()
        end,
        thinking = function()
            if self.live.text == "" then
                self.state = "thinking"
                self:_bump()
            end
        end,
        done = function(info) self.doneInfo = info end,
        error = function(msg) self.errMsg = msg or "Stream error" end,
    })
end

-- Ends the current request with an error note; keeps partial text.
function Chat:_finishFailed(noteText)
    local live = self.live
    self.state, self.live = "idle", nil
    self.req, self.sse, self.parserFeed = nil, nil, nil
    if live and live.text ~= "" then
        self.items[#self.items + 1] = {
            role = "assistant", provider = self.providerId, model = self.model,
            text = live.text, stopped = true,
        }
    end
    self:_push("error", noteText, true)
    self:_persist()
    self:_bump()
end

function Chat:stop()
    if self.state == "idle" then return end
    local live = self.live
    if self.req then self.req:cancel() end
    self.state, self.live = "idle", nil
    self.req, self.sse, self.parserFeed, self.retryAt = nil, nil, nil, nil
    if live and live.text ~= "" then
        local item = {
            role = "assistant", provider = self.providerId, model = self.model,
            text = live.text, stopped = true,
        }
        self.items[#self.items + 1] = item
        self:_savePrograms(item, true)
    end
    self:_push("info", "Reply stopped")
    self:_persist()
end

-- Saves the programs in a reply (spec 9.1). A stopped reply keeps only blocks
-- whose fence closed. item.programs lists the reply's lua code blocks in order:
-- the saved name, or false for a block that isn't a saved program (omitted when
-- none was saved). Also sets self.programs and self.lastProgramName.
function Chat:_savePrograms(item, closedOnly)
    local progs = self.deps.programs
    if not progs or item.text == "" then return end
    local list, nBlocks = Programs.extract(item.text, closedOnly)
    if #list == 0 then return end
    local clock = self:_clock()
    if not self.id then self.id = self.deps.store:newId(clock) end
    local saved, err = progs:save(self.id, list, clock.synced and clock.epoch or nil)
    if err then self:_push("error", "Couldn't save program: " .. tostring(err), true) end
    local per, last = {}, nil
    for i = 1, nBlocks do per[i] = false end
    local all, have = {}, {}
    for _, n in ipairs(self.programs or {}) do all[#all + 1] = n; have[n] = true end
    for i, p in ipairs(list) do
        local name = saved[i]
        if name then
            per[p.block], last = name, name
            if not have[name] then all[#all + 1] = name; have[name] = true end
        end
    end
    if not last then return end
    item.programs = per
    self.lastProgramName = last
    self.programs = all
end

-- A finished reply: store it, stop notes, long-chat note, hook, save, title.
function Chat:_complete(info)
    local live = self.live
    self.state, self.live = "idle", nil
    if self.req then self.req:cancel() end
    self.req, self.sse, self.parserFeed = nil, nil, nil
    local item = {
        role = "assistant", provider = self.providerId, model = self.model, text = live.text,
    }
    if info.raw and #info.raw > 0 then item.raw = info.raw end
    if live.text ~= "" or item.raw then self.items[#self.items + 1] = item end
    if info.stop == "length" then
        self:_push("info", "Reply cut off at the length limit.")
    elseif info.stop == "refusal" then
        local P = self.reqProv
        self:_push("info", P.modelInfo(self.model).label .. " declined to answer this.")
    end
    if not self.longNoted then
        local ok, s = pcall(self.deps.pc.json.encode, self.items)
        if ok and #s > Chat.LONG_BYTES then
            self.longNoted = true
            self:_push("info", LONG_NOTE)
        end
    end
    self:_savePrograms(item, false)
    local saved = self:_persist()
    self:_bump()
    if saved and item.text ~= "" and self.titlePending then self:_startTitle() end
end

-- ------------------------------------------------------------------- titles

function Chat:_startTitle()
    local deps, P = self.deps, self:provider()
    if self.titleReq then return end
    local key = self:_key(P)
    local first, reply
    for _, it in ipairs(self.items) do
        if it.role == "user" and not first then first = it.text end
        if it.role == "assistant" and not reply then reply = it.text end
    end
    if not key or not first or not reply or not self:_online() then
        self.titlePending = false
        return
    end
    local path, headers, body = P.titleRequest(deps.pc.json, key, first, reply)
    self.titleProv = P
    self.titleReq = Http.post(deps.pc.network, deps.store:base(P.id) or P.BASE, path, headers, body)
    self.titleChunks = {}
    self.titling = true
end

function Chat:_tickTitle()
    local req = self.titleReq
    for _, c in ipairs(req:take()) do self.titleChunks[#self.titleChunks + 1] = c end
    if req.state == "sending" or req.state == "streaming" then return end
    self.titleReq, self.titling = nil, false
    self.titlePending = false -- one try per chat; failures keep the cut message
    if req.state ~= "done" or req.status ~= 200 then return end
    local P = self.titleProv
    local json = self.deps.pc.json
    local clean = Titles.clean(P.titleText(json, table.concat(self.titleChunks)))
    if clean then
        self.title = clean
        self:_persist()
        self:_bump()
    end
end

function Chat:cancelTitle()
    if self.titleReq then
        self.titleReq:cancel()
        self.titleReq, self.titling = nil, false
        self.titlePending = true -- sent again after the next reply
    end
end

-- -------------------------------------------------------------------- tick

function Chat:_tickReply(now)
    if self.retryAt then
        if now >= self.retryAt then
            self.retryAt = nil
            self:_launch()
        end
        return
    end
    local req = self.req
    if not req then return end
    local chunks = req:take()
    if req.status == 200 then
        for _, c in ipairs(chunks) do
            self.sse:feed(c)
            if self.doneInfo or self.errMsg then break end
        end
    elseif req.status then
        self.errBody = self.errBody or {}
        for _, c in ipairs(chunks) do self.errBody[#self.errBody + 1] = c end
    end

    if self.doneInfo then
        return self:_complete(self.doneInfo)
    end
    if self.errMsg then
        local m = self.errMsg
        req:cancel()
        return self:_finishFailed(LOST_NOTE .. "\n" .. m)
    end
    if req.state == "failed" then
        local err = tostring(req.err or "connection failed")
        if err:find("^clock not set") then
            if not self.clockRetried then
                self.clockRetried = true
                self.req, self.sse, self.parserFeed = nil, nil, nil
                self.retryAt = now + Chat.CLOCK_RETRY_MS
                return
            end
            self.clockRetried = false
            return self:_finishFailed("The clock isn't set yet; try again in a moment.")
        end
        self.clockRetried = false
        if req.status and req.status ~= 200 then
            local body = table.concat(self.errBody or {})
            return self:_finishFailed(self.reqProv.describeError(self.deps.pc.json, req.status, body, req.retryAfter))
        end
        if req.status then return self:_finishFailed(LOST_NOTE) end
        return self:_finishFailed(err)
    elseif req.state == "done" then
        self.clockRetried = false
        if req.status ~= 200 then
            local body = table.concat(self.errBody or {})
            local text = self.reqProv.describeError(self.deps.pc.json, req.status, body, req.retryAfter)
            return self:_finishFailed(text)
        end
        self.sse:finish()
        if self.doneInfo then return self:_complete(self.doneInfo) end
        if self.errMsg then return self:_finishFailed(LOST_NOTE .. "\n" .. self.errMsg) end
        return self:_finishFailed(LOST_NOTE) -- the stream ended without its last event
    end
end

-- Call every frame. nowMs: sys.getTimeMs().
function Chat:tick(nowMs)
    nowMs = nowMs or self.deps.pc.sys.getTimeMs()
    if self.state ~= "idle" then self:_tickReply(nowMs) end
    if self.titleReq then self:_tickTitle() end
end

return Chat
