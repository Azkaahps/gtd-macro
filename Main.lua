--[[
================================================================================
  ANON · Garden Tower Defense — Macro Recorder & Replay
  target : Roblox | [🕸️] Garden Tower Defense 🌻
           place 108533757090220 / 123516946198836   universe 7703614594
  build  : Android first (Delta), also runs on PC executors
  version: 1.0.0
  ---------------------------------------------------------------- what it does
  Records raw player input (tap / drag / key) with an anchor of (wave, dt-from-
  wave-start), and stamps every recording with the auto-detected context:
  mode, difficulty, map, map signature, game speed, total waves, loadout units,
  place id, job id. History stores those stamps so a macro can only be played
  back on the run it was made for -- or at least warns you when it is not.
  ------------------------------------------------------------------- layout
  [1] core    services, config, utils, file store, macro persistence
  [2] probe   discovery: gui text, workspace signature, containers, remotes
  [3] engine  recorder + wave-synced replay player
  [4] ui      touch-first interface
================================================================================
--]]

--==============================================================================
-- [1] CORE
--==============================================================================

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local HttpService       = game:GetService("HttpService")
local TweenService      = game:GetService("TweenService")
local StarterGui        = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser       = game:GetService("VirtualUser")
local Workspace         = game:GetService("Workspace")

local LP = Players.LocalPlayer
local CAM = Workspace.CurrentCamera

local VIM = nil
do
    local ok, svc = pcall(function() return game:GetService("VirtualInputManager") end)
    if ok then VIM = svc end
end

local unpack = table.unpack or unpack

--==============================================================================
-- CONFIG
--==============================================================================

local CONFIG = {
    version        = "1.1.0",
    root_dir       = "ANON_GTD",
    place_whitelist= { [108533757090220] = "Garden Tower Defense", [123516946198836] = "Garden Tower Defense (2)" },

    -- input fidelity
    jitter_pos     = 2,        -- px, 0 = frame perfect (bot-like)
    jitter_time    = 0.010,    -- s
    click_mode     = "auto",   -- auto | mouse | touch | ui
    tap_offset_x   = 0,        -- calibrated, see SETUP tab
    tap_offset_y   = 0,
    follow_ui      = true,     -- re-resolve UI element position at play time
    follow_world   = true,     -- re-project recorded world points through the live camera

    -- wave sync
    anchor_mode    = "auto",   -- auto | gui | remote | absolute
    speed_mode     = "scale",  -- scale | block   (behaviour when game speed differs)
    wave_timeout   = 45,       -- s to wait for the anchor of a step's wave
    skip_on_wave_timeout = true, -- never tap at the wrong moment: drop the step instead
    verify_timeout = 1.5,      -- s to wait for a placement to actually land
    retries        = 2,

    -- housekeeping
    anti_afk       = true,
    notify         = true,
    max_steps      = 8000,
    scan_labels    = true,
    -- while recording, fold the panel down to the mini bar: on a phone the open
    -- panel covers a big part of the screen and those taps are correctly ignored,
    -- which on a small screen means "recorded nothing at all"
    auto_collapse_on_record = true,
}

--==============================================================================
-- UTILS
--==============================================================================

local U = {}

function U.now()
    return os.clock()
end

function U.clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

function U.round(v)
    return math.floor(v + 0.5)
end

function U.fmt_secs(s)
    s = math.max(0, math.floor(s or 0))
    return string.format("%02d:%02d:%02d", math.floor(s / 3600), math.floor((s % 3600) / 60), s % 60)
end

function U.fmt_ms(s)
    s = math.max(0, math.floor(s or 0))
    return string.format("%02d:%02d", math.floor(s / 60), s % 60)
end

function U.fmt_date(t)
    local ok, out = pcall(function() return os.date("%Y-%m-%d %H:%M", t) end)
    if ok and out then return out end
    return "?"
end

function U.rand(a, b)
    return a + math.random() * (b - a)
end

-- 32-bit-ish stable hash without bitwise ops (keeps lua 5.1 / luau both happy)
function U.hash(tbl)
    local h = 5381
    for i = 1, #tbl do
        local s = tostring(tbl[i])
        for j = 1, #s do
            h = (h * 33 + string.byte(s, j)) % 4294967296
        end
    end
    return h
end

function U.base64_encode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    local n = 0
    local buf = 0
    for i = 1, #data do
        buf = buf * 256 + string.byte(data, i)
        n = n + 1
        if n == 3 then
            local c1 = math.floor(buf / 65536) % 64
            local c2 = math.floor(buf / 4096) % 64
            local c3 = math.floor(buf / 64) % 64
            local c4 = buf % 64
            out[#out + 1] = string.sub(b, c1 + 1, c1 + 1)
            out[#out + 1] = string.sub(b, c2 + 1, c2 + 1)
            out[#out + 1] = string.sub(b, c3 + 1, c3 + 1)
            out[#out + 1] = string.sub(b, c4 + 1, c4 + 1)
            buf = 0
            n = 0
        end
    end
    if n == 1 then
        buf = buf * 65536
        local c1 = math.floor(buf / 65536) % 64
        local c2 = math.floor(buf / 4096) % 64
        out[#out + 1] = string.sub(b, c1 + 1, c1 + 1)
        out[#out + 1] = string.sub(b, c2 + 1, c2 + 1)
        out[#out + 1] = "=="
    elseif n == 2 then
        buf = buf * 256
        local c1 = math.floor(buf / 65536) % 64
        local c2 = math.floor(buf / 4096) % 64
        local c3 = math.floor(buf / 64) % 64
        out[#out + 1] = string.sub(b, c1 + 1, c1 + 1)
        out[#out + 1] = string.sub(b, c2 + 1, c2 + 1)
        out[#out + 1] = string.sub(b, c3 + 1, c3 + 1)
        out[#out + 1] = "="
    end
    return table.concat(out)
end

function U.base64_decode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local lut = {}
    for i = 1, #b do lut[string.sub(b, i, i)] = i - 1 end
    data = string.gsub(data, "[^" .. b .. "=]", "")
    local out = {}
    local buf, n = 0, 0
    for i = 1, #data do
        local ch = string.sub(data, i, i)
        if ch == "=" then break end
        local v = lut[ch]
        if v then
            buf = buf * 64 + v
            n = n + 1
            if n == 4 then
                local c1 = math.floor(buf / 16777216) % 256
                local c2 = math.floor(buf / 65536) % 256
                local c3 = math.floor(buf / 256) % 256
                local c4 = buf % 256
                out[#out + 1] = string.char(c1, c2, c3, c4)
                buf, n = 0, 0
            end
        end
    end
    if n == 3 then
        buf = buf * 64
        out[#out + 1] = string.char(math.floor(buf / 65536) % 256, math.floor(buf / 256) % 256)
    elseif n == 2 then
        buf = buf * 256
        out[#out + 1] = string.char(math.floor(buf / 65536) % 256)
    end
    return table.concat(out)
end

function U.json_encode(v)
    local ok, s = pcall(function() return HttpService:JSONEncode(v) end)
    if ok then return s end
    return nil
end

function U.json_decode(s)
    local ok, v = pcall(function() return HttpService:JSONDecode(s) end)
    if ok then return v end
    return nil
end

function U.notify(title, text, dur)
    if not CONFIG.notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title or "ANON GTD",
            Text = tostring(text or ""),
            Duration = dur or 4,
        })
    end)
end

function U.spawn(fn, ...)
    local args = { ... }
    local ok, err = pcall(function()
        task.spawn(function() fn(unpack(args)) end)
    end)
    if not ok then warn("[ANON GTD] spawn failed: " .. tostring(err)) end
end

--==============================================================================
-- COLOUR CONTRAST
-- WCAG relative luminance. Nothing in this UI is allowed to draw text in a colour
-- that is close to its own background. ui.audit_contrast() is the self test.
--==============================================================================

local INK   = Color3.fromRGB(14, 15, 18)     -- matches C.bg, near black
local PAPER = Color3.fromRGB(232, 234, 238)  -- matches C.text, near white

local function srgb_channel(v)
    v = v / 255
    if v <= 0.03928 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end

function U.lum(col)
    return 0.2126 * srgb_channel(col.R) + 0.7152 * srgb_channel(col.G) + 0.0722 * srgb_channel(col.B)
end

function U.contrast(a, b)
    local la, lb = U.lum(a), U.lum(b)
    local hi = math.max(la, lb)
    local lo = math.min(la, lb)
    return (hi + 0.05) / (lo + 0.05)
end

-- the legible colour for a given background (whatever contrasts best)
function U.on_color(bg)
    if U.contrast(PAPER, bg) >= U.contrast(INK, bg) then return PAPER end
    return INK
end

-- keep the intended colour when it is readable, otherwise swap it for a legible one
function U.fix_contrast(text_col, bg, min_ratio)
    if not bg then return text_col or PAPER end
    if text_col and U.contrast(text_col, bg) >= (min_ratio or 4.0) then return text_col end
    return U.on_color(bg)
end

--==============================================================================
-- FILE STORE
--==============================================================================

local FS = {}

FS.available = (type(writefile) == "function")
    and (type(readfile) == "function")
    and (type(isfolder) == "function")
    and (type(makefolder) == "function")
    and (type(listfiles) == "function")
    and (type(delfile) == "function")

FS.has_isfile = (type(isfile) == "function")

local MEM = { files = {} }

function FS.ensure(dir)
    if not FS.available then return false end
    local ok = pcall(function()
        if not isfolder(dir) then makefolder(dir) end
    end)
    return ok
end

function FS.write(path, data)
    if FS.available then
        local ok = pcall(function() writefile(path, data) end)
        return ok
    end
    MEM.files[path] = data
    return true
end

-- always the in-memory copy, used as a last resort when the disk write fails
function FS.write_mem(path, data)
    MEM.files[path] = data
    return true
end

function FS.read(path)
    if FS.available then
        local ok, data = pcall(function() return readfile(path) end)
        if ok and data ~= nil then return data end
        -- a macro that only ever reached memory must still be loadable this session
        return MEM.files[path]
    end
    return MEM.files[path]
end

function FS.exists(path)
    if not FS.available then return MEM.files[path] ~= nil end
    if FS.has_isfile then
        local ok, res = pcall(function() return isfile(path) end)
        if ok then return res end
    end
    local ok, res = pcall(function() return readfile(path) end)
    return ok and res ~= nil
end

function FS.list(dir)
    if not FS.available then
        local out = {}
        for k in pairs(MEM.files) do
            if string.find(k, dir, 1, true) == 1 then out[#out + 1] = k end
        end
        return out
    end
    local ok, res = pcall(function() return listfiles(dir) end)
    if ok and type(res) == "table" then return res end
    return {}
end

function FS.remove(path)
    if not FS.available then
        MEM.files[path] = nil
        return true
    end
    local ok = pcall(function() delfile(path) end)
    return ok
end

--==============================================================================
-- STORE  (macro history + pin)
--==============================================================================

local STORE = {}
STORE.dir       = CONFIG.root_dir .. "/macros"
STORE.indexpath = CONFIG.root_dir .. "/index.json"
STORE.profilepath = CONFIG.root_dir .. "/profile.json"

STORE.index   = {}
STORE.profile = { tap_offset_x = 0, tap_offset_y = 0, wave_path = nil, wave_src = nil, container_path = nil, enemy_path = nil, remote_path = nil, overrides = {} }

-- If the index was lost but macro files are on disk, rebuild it from them: a save
-- that reached the disk must never be invisible just because index.json failed.
function STORE.rebuild_index()
    if not FS.available then return 0 end
    local files = FS.list(STORE.dir)
    local added = 0
    local seen = {}
    for _, e in ipairs(STORE.index.entries) do seen[e.id] = true end
    local scanned = 0
    for _, path in ipairs(files) do
        local id = string.match(path, "([^/\\]+)%.json$")
        if id and not seen[id] and scanned < 200 then
            scanned = scanned + 1
            local raw = FS.read(path)
            local m = raw and U.json_decode(raw)
            if type(m) == "table" and type(m.steps) == "table" then
                local ctx = m.ctx or {}
                table.insert(STORE.index.entries, {
                    id = id,
                    name = m.name or id,
                    pinned = m.pinned and true or false,
                    created = m.created or 0,
                    steps = #m.steps,
                    duration = m.duration,
                    mode = ctx.mode,
                    difficulty = ctx.difficulty,
                    map = ctx.map,
                    map_sig = ctx.map_sig,
                    speed = ctx.speed,
                    wave_total = ctx.wave_total,
                    units = ctx.loadout,
                    place_id = ctx.place_id,
                    recovered = true,
                })
                seen[id] = true
                added = added + 1
            end
        end
    end
    if added > 0 then STORE.save_index() end
    return added
end

function STORE.diagnose()
    local entries = (STORE.index and STORE.index.entries) or {}
    local macro_files = 0
    for _, p in ipairs(FS.list(STORE.dir)) do
        if string.find(p, "%.json$") then macro_files = macro_files + 1 end
    end
    local mem_only = 0
    for _, e in ipairs(entries) do
        if e.memory_only then mem_only = mem_only + 1 end
    end
    local lines = {
        "file api     : " .. (FS.available and "yes" or "NO - macros live only for this session"),
        "folder       : " .. STORE.dir,
        "files on disk: " .. tostring(macro_files),
        "index entries: " .. tostring(#entries) .. (mem_only > 0 and (" (" .. tostring(mem_only) .. " memory only)") or ""),
        "profile      : " .. STORE.profilepath,
    }
    return table.concat(lines, "\n"), { files = macro_files, entries = #entries, memory_only = mem_only }
end

function STORE.init()
    FS.ensure(CONFIG.root_dir)
    FS.ensure(STORE.dir)

    local raw = FS.read(STORE.indexpath)
    if raw then
        local t = U.json_decode(raw)
        if type(t) == "table" and type(t.entries) == "table" then STORE.index = t end
    end
    if type(STORE.index.entries) ~= "table" then STORE.index = { entries = {} } end

    local praw = FS.read(STORE.profilepath)
    if praw then
        local p = U.json_decode(praw)
        if type(p) == "table" then
            for k, v in pairs(p) do STORE.profile[k] = v end
        end
    end
    CONFIG.tap_offset_x = STORE.profile.tap_offset_x or 0
    CONFIG.tap_offset_y = STORE.profile.tap_offset_y or 0

    -- anything on disk that the index does not know about (lost or half-written
    -- index.json) gets picked back up here
    STORE.recovered = STORE.rebuild_index()
end

function STORE.save_index()
    FS.write(STORE.indexpath, U.json_encode(STORE.index) or "{\"entries\":[]}")
end

function STORE.save_profile()
    STORE.profile.tap_offset_x = CONFIG.tap_offset_x
    STORE.profile.tap_offset_y = CONFIG.tap_offset_y
    FS.write(STORE.profilepath, U.json_encode(STORE.profile) or "{}")
end

function STORE.macro_path(id)
    return STORE.dir .. "/" .. id .. ".json"
end

function STORE.entry_of(id)
    for _, e in ipairs(STORE.index.entries) do
        if e.id == id then return e end
    end
    return nil
end

function STORE.save_macro(macro)
    local raw = U.json_encode(macro)
    if not raw then return false, "json encode failed" end

    local wrote = FS.write(STORE.macro_path(macro.id), raw)
    local memory_only = false
    if not wrote then
        -- the disk refused it: keep it in memory anyway so the recording is visible,
        -- playable and exportable instead of vanishing without a trace
        FS.write_mem(STORE.macro_path(macro.id), raw)
        memory_only = true
    end

    local entry = STORE.entry_of(macro.id)
    if not entry then
        entry = { id = macro.id }
        table.insert(STORE.index.entries, entry)
    end
    entry.name       = macro.name
    entry.pinned     = macro.pinned and true or false
    entry.created    = macro.created
    entry.steps      = #macro.steps
    entry.duration   = macro.duration
    entry.mode       = macro.ctx.mode
    entry.difficulty = macro.ctx.difficulty
    entry.map        = macro.ctx.map
    entry.map_sig    = macro.ctx.map_sig
    entry.speed      = macro.ctx.speed
    entry.wave_total = macro.ctx.wave_total
    entry.units      = macro.ctx.loadout
    entry.place_id   = macro.ctx.place_id
    entry.memory_only = memory_only
    STORE.save_index()
    return true, memory_only and "memory only (disk write failed)" or nil
end

function STORE.load_macro(id)
    local raw = FS.read(STORE.macro_path(id))
    if not raw then return nil end
    local m = U.json_decode(raw)
    if type(m) ~= "table" or type(m.steps) ~= "table" then return nil end
    return m
end

function STORE.delete_macro(id)
    FS.remove(STORE.macro_path(id))
    for i = #STORE.index.entries, 1, -1 do
        if STORE.index.entries[i].id == id then table.remove(STORE.index.entries, i) end
    end
    STORE.save_index()
end

function STORE.pin(id, state)
    local e = STORE.entry_of(id)
    if not e then return end
    e.pinned = state and true or false
    STORE.save_index()
    local m = STORE.load_macro(id)
    if m then
        m.pinned = e.pinned
        STORE.save_macro(m)
    end
end

function STORE.rename(id, name)
    local e = STORE.entry_of(id)
    if not e then return end
    e.name = name
    STORE.save_index()
    local m = STORE.load_macro(id)
    if m then
        m.name = name
        STORE.save_macro(m)
    end
end

function STORE.sorted_entries()
    local list = {}
    for _, e in ipairs(STORE.index.entries) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        if (a.pinned and true or false) ~= (b.pinned and true or false) then
            return a.pinned and true or false
        end
        return (a.created or 0) > (b.created or 0)
    end)
    return list
end

function STORE.new_id()
    local t = os.date("*t")
    return string.format("%04d%02d%02d-%02d%02d%02d-%03d",
        t.year, t.month, t.day, t.hour, t.min, t.sec, math.random(0, 999))
end

--==============================================================================
-- SHARED SURFACE
-- declared here so every later section can reach it (single chunk, no load order
-- surprises). UI fills the stubs in when it is built.
--==============================================================================

local UI_API = {
    contains_point = function() return false end,
    status         = function() end,
    toast          = function() end,
    live_step      = function() end,
    refresh_macros = function() end,
    collapse       = function() end,
}

-- "game.Workspace.Folder.Model" -> Instance  (case tolerant, dup tolerant)
local function resolve_path(path)
    if type(path) ~= "string" or path == "" then return nil end
    local cur = game
    for seg in string.gmatch(path, "[^%.]+") do
        local nxt = cur:FindFirstChild(seg)
        if not nxt then
            local ok, kids = pcall(function() return cur:GetChildren() end)
            if ok and kids then
                local low = string.lower(seg)
                for _, c in ipairs(kids) do
                    if string.lower(c.Name) == low then
                        nxt = c
                        break
                    end
                end
            end
        end
        if not nxt then return nil end
        cur = nxt
    end
    return cur
end
--==============================================================================
-- [2] PROBE — discovery of everything the game does not tell us by name
--==============================================================================

local PROBE = {}

PROBE.spy_supported = (type(hookmetamethod) == "function")
    and (type(getrawmetatable) == "function")
    and (type(newcclosure) == "function")
    and (type(getnamecallmethod) == "function")

PROBE.spy_log = {}      -- [remoteName] = { count = n, samples = { {args preview}, ... } }
PROBE.report  = {}      -- last discovery report (also written to disk)

local CLASS_KEYWORDS = {
    wave   = { "wave", "round", "ronde", "level" },
    mode   = { "classic", "survival", "dojo", "endless", "infinite", "back garden", "backgarden", "pvp", "2v2", "afk", "event" },
    diff   = { "easy", "normal", "hard", "impossible", "insane", "nightmare", "extreme" },
    start  = { "start", "next", "begin", "countdown", "starting in", "arrive" },
    seed   = { "seed" },
    map    = { "map" },
    speed  = { "speed", "x1", "x2", "x3" },
    unit   = { "unit", "tower", "plant", "placed", "equipped" },
}

local function lower(s)
    return string.lower(tostring(s or ""))
end

local function contains_any(s, list)
    s = lower(s)
    for _, k in ipairs(list) do
        if string.find(s, k, 1, true) then return true end
    end
    return false
end

PROBE.contains_any = contains_any

--==============================================================================
-- gui roots / label scan
--==============================================================================

function PROBE.gui_roots()
    local roots = {}
    if LP then
        local pg = LP:FindFirstChild("PlayerGui")
        if pg then roots[#roots + 1] = pg end
    end
    local ok, hui = pcall(function()
        if type(gethui) == "function" then return gethui() end
        return nil
    end)
    if ok and hui and hui ~= LP and hui ~= (LP and LP:FindFirstChild("PlayerGui")) then
        roots[#roots + 1] = hui
    end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then roots[#roots + 1] = cg end
    return roots
end

-- returns list of { obj = TextLabel|TextButton|TextBox, text = string, path = string }
function PROBE.labels()
    local out = {}
    for _, root in ipairs(PROBE.gui_roots()) do
        local ok, list = pcall(function() return root:GetDescendants() end)
        if ok and list then
            for _, d in ipairs(list) do
                local cls = d.ClassName
                if cls == "TextLabel" or cls == "TextButton" or cls == "TextBox" then
                    if d.Visible then
                        local t = d.Text
                        if type(t) == "string" and t ~= "" then
                            out[#out + 1] = { obj = d, text = t, path = d:GetFullName() }
                        end
                    end
                end
            end
        end
    end
    return out
end

--==============================================================================
-- data-value scan  (NumberValue / StringValue / attributes)
--==============================================================================

function PROBE.data_values()
    local out = {}
    local containers = { ReplicatedStorage, Workspace }
    for _, c in ipairs(containers) do
        local ok, list = pcall(function() return c:GetDescendants() end)
        if ok and list then
            local n = 0
            for _, d in ipairs(list) do
                if d:IsA("ValueBase") then
                    local okv, v = pcall(function() return d.Value end)
                    if okv then
                        out[#out + 1] = { path = d:GetFullName(), name = d.Name, value = v }
                        n = n + 1
                    end
                end
                if n > 400 then break end
            end
        end
    end
    return out
end

function PROBE.attributes_of(inst)
    local out = {}
    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if ok and attrs then
        for k, v in pairs(attrs) do out[k] = v end
    end
    return out
end

--==============================================================================
-- workspace signature  (the map fingerprint)
--==============================================================================

function PROBE.map_signature()
    local names = {}
    local ok, kids = pcall(function() return Workspace:GetChildren() end)
    if ok and kids then
        for _, c in ipairs(kids) do
            names[#names + 1] = c.ClassName .. ":" .. c.Name
            local ok2, sub = pcall(function() return c:GetChildren() end)
            if ok2 and sub then
                local cap = 8
                for i = 1, math.min(#sub, cap) do
                    names[#names + 1] = sub[i].ClassName .. ":" .. sub[i].Name
                end
            end
        end
    end
    table.sort(names)
    local trimmed = {}
    for i = 1, math.min(#names, 80) do trimmed[i] = names[i] end
    return U.hash(trimmed), trimmed
end

--==============================================================================
-- VERIFIED GDT INTERNALS
-- Not guesses. These names were read out of two independent public hubs for this
-- exact game (Ard Hub v2.5.5 — plaintext, 154 KB; and a placement tracker /
-- in-game UI pair from Tseting-nil/Garden-Tower-Defense-script, plaintext).
-- They are tried FIRST and the generic probes stay as the fallback, because GDT
-- ships a patch every Saturday and any of these can move.
--==============================================================================

PROBE.KNOWN = {
    remote_functions  = "RemoteFunctions",  -- flat folder, everything is InvokeServer
    remote_events     = "RemoteEvents",
    entities_folder   = "Entities",         -- towers + enemies; enemies are named "enemy_*"
    place_unit        = "PlaceUnit",        -- InvokeServer(unitId, cframe-ish)
    sell_unit         = "SellUnit",
    skip_wave         = "SkipWave",
    ability           = "ActivateUnitAbility",
    sell_all          = "SellAll",
    speed_remote      = "ChangeTickSpeed",  -- RemoteEvent, FireServer(speed)
    autoskip_remote   = "SetAutoSkip",
    targeting_remote  = "Entity_ChangeTargetingMode",
}

-- the run context is a folder in workspace carrying the run as attributes; legacy
-- builds kept the same attributes directly on workspace
function PROBE.run_context()
    local ok, kids = pcall(function() return Workspace:GetChildren() end)
    if not ok or not kids then return nil end
    local best, best_score = nil, 0
    for _, c in ipairs(kids) do
        if c:IsA("Folder") or c:IsA("Model") then
            local score = 0
            local okg = pcall(function()
                if c:GetAttribute("GameStartTime") ~= nil then score = score + 3 end
                if c:GetAttribute("RunId") ~= nil then score = score + 2 end
                if c:GetAttribute("Config") ~= nil then score = score + 2 end
                if c:FindFirstChild(PROBE.KNOWN.entities_folder) then score = score + 2 end
            end)
            if okg and score > best_score then best, best_score = c, score end
        end
    end
    if best and best_score >= 2 then return best end
    return nil
end

-- attribute lookup: run context first, then the legacy workspace location
function PROBE.attr(name)
    local ctx = PROBE.run_context()
    if ctx then
        local ok, v = pcall(function() return ctx:GetAttribute(name) end)
        if ok and v ~= nil then return v, ctx:GetFullName() .. " attr:" .. name end
    end
    local ok2, wv = pcall(function() return Workspace:GetAttribute(name) end)
    if ok2 and wv ~= nil then return wv, "Workspace attr:" .. name end
    return nil, nil
end

-- Config is a JSON string attribute on the run context: { mapId = ..., night = ... }
function PROBE.config_field(key)
    local raw = PROBE.attr("Config")
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, t = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok and type(t) == "table" then return t[key] end
    return nil
end

-- raw difficulty ids the game uses in its attributes
local DIFF_ID = {
    dif_easy = "Easy", dif_normal = "Normal", dif_hard = "Hard",
    dif_insane = "Impossible", dif_nightmare = "Nightmare", dif_extreme = "Extreme",
    dif_sandbox = "Sandbox",
}

function PROBE.difficulty_from_attr()
    local raw = PROBE.attr("Difficulty")
    if type(raw) ~= "string" or raw == "" then return nil, nil end
    local mapped = DIFF_ID[string.lower(raw)]
    if mapped then return mapped, "attr:Difficulty" end
    return (string.gsub(raw, "^dif_", "")), "attr:Difficulty"
end

-- towers and enemies live in the same Entities folder; enemies carry the prefix
function PROBE.entities()
    local ctx = PROBE.run_context()
    local f = ctx and ctx:FindFirstChild(PROBE.KNOWN.entities_folder)
    if not f then
        local map = Workspace:FindFirstChild("Map")
        f = map and map:FindFirstChild(PROBE.KNOWN.entities_folder)
    end
    if not f then
        local ok, list = pcall(function() return Workspace:GetDescendants() end)
        if ok and list then
            for _, d in ipairs(list) do
                if d.Name == PROBE.KNOWN.entities_folder and (d:IsA("Folder") or d:IsA("Model")) then
                    f = d
                    break
                end
            end
        end
    end
    return f
end

-- every placed unit carries a numeric ID attribute = its server gameId. Wrapped
-- "moves around" units keep the ID on an inner model with the same name.
function PROBE.entity_id(model)
    if not model then return nil end
    local ok, id = pcall(function() return model:GetAttribute("ID") end)
    if ok and type(id) == "number" then return id end
    local okn, name = pcall(function() return model.Name end)
    if okn and name then
        local inner = model:FindFirstChild(name)
        if inner then
            local ok2, iid = pcall(function() return inner:GetAttribute("ID") end)
            if ok2 and type(iid) == "number" then return iid end
        end
    end
    return nil
end

function PROBE.is_enemy(model)
    if not model then return false end
    local ok, name = pcall(function() return model.Name end)
    return ok and name and string.match(name, "^enemy_") ~= nil
end

-- the in-game header prints one line we can parse: "Map: X | Difficulty: Y | Modifier: Z"
function PROBE.header_map_line(labels)
    for _, e in ipairs(labels or PROBE.labels()) do
        local t = e.text
        if string.find(t, "Map:", 1, true) then
            local m, d, mo = string.match(t,
                "Map:%s*(.-)%s*|%s*Difficulty:%s*(.-)%s*|%s*Modifier:%s*(.-)%s*$")
            if m and m ~= "" then return m, d, mo, e.path end
            local m2, d2 = string.match(t, "Map:%s*(.-)%s*|%s*Difficulty:%s*(.-)%s*$")
            if m2 and m2 ~= "" then return m2, d2, nil, e.path end
        end
    end
    return nil
end

--==============================================================================
-- context detection  (the differentiator stamped into every macro)
--==============================================================================

local MODE_SET = {
    ["classic"] = "Classic", ["survival"] = "Survival", ["dojo"] = "Dojo",
    ["endless"] = "Endless", ["infinite"] = "Endless", ["afk"] = "AFK",
    ["back garden"] = "Back Garden", ["backgarden"] = "Back Garden",
    ["pvp"] = "PvP", ["2v2"] = "PvP 2v2", ["event"] = "Event", ["sandbox"] = "Sandbox",
}

local DIFF_SET = {
    ["easy"] = "Easy", ["normal"] = "Normal", ["hard"] = "Hard",
    ["impossible"] = "Impossible", ["insane"] = "Impossible", ["nightmare"] = "Nightmare",
    ["extreme"] = "Extreme",
}

local function match_set(text, set)
    local t = lower(text)
    for k, v in pairs(set) do
        if t == k then return v end
        if string.find(t, k, 1, true) then
            -- require the token to be the whole meaningful part of the label
            if #t <= #k + 8 then return v end
        end
    end
    return nil
end

-- pull a "current / selected" value out of gui labels
function PROBE.detect_context()
    local ctx = {
        place_id    = game.PlaceId,
        job_id      = game.JobId,
        mode        = nil,
        difficulty  = nil,
        map         = nil,
        map_sig     = nil,
        map_parts   = nil,
        speed       = nil,
        wave_total  = nil,
        wave_cur    = nil,
        seeds       = nil,
        loadout     = {},
        seed_count  = 0,
        sources     = {},
        captured_at = os.time(),
    }

    -- workspace fingerprint always available
    local sig, parts = PROBE.map_signature()
    ctx.map_sig, ctx.map_parts = sig, parts

    local labels = PROBE.labels()
    ctx.label_count = #labels

    -- ── verified game state first ──────────────────────────────────────────────
    -- attributes beat every label heuristic: they are the server's own values
    local run_ctx = PROBE.run_context()
    if run_ctx then
        ctx.run_context = run_ctx:GetFullName()
        local okr, rid = pcall(function() return run_ctx:GetAttribute("RunId") end)
        if okr then ctx.run_id = rid end
    end

    local gst, gst_src = PROBE.attr("GameStartTime")
    if type(gst) == "number" and gst > 0 then
        ctx.game_start_time = gst
        ctx.game_elapsed = math.max(0, os.time() - gst)
        ctx.sources.game_start = gst_src
    end

    local diff_attr, diff_src = PROBE.difficulty_from_attr()
    if diff_attr then
        ctx.difficulty = diff_attr
        ctx.difficulty_id = PROBE.attr("Difficulty")
        ctx.sources.difficulty = diff_src
    end

    local night = PROBE.attr("Night")
    if night == nil then night = PROBE.config_field("night") end
    if night ~= nil then ctx.night = night and true or false end

    local header_map, header_diff, header_mod, header_path = PROBE.header_map_line(labels)
    if header_map then
        if not ctx.map then
            ctx.map = header_map
            ctx.sources.map = header_path
        end
        if not ctx.difficulty and header_diff and header_diff ~= "" then
            ctx.difficulty = header_diff
            ctx.sources.difficulty = header_path
        end
        if header_mod and header_mod ~= "" and header_mod ~= "None" then
            ctx.modifier = header_mod
        end
    end

    if not ctx.map then
        local map_attr = PROBE.attr("MapId")
        if type(map_attr) == "string" and map_attr ~= "" then
            ctx.map = map_attr
            ctx.sources.map = "attr:MapId"
        end
    end
    if not ctx.map then
        local cfg_map = PROBE.config_field("mapId")
        if type(cfg_map) == "string" and cfg_map ~= "" then
            ctx.map = cfg_map
            ctx.sources.map = "config:mapId"
        end
    end

    local entities = PROBE.entities()
    if entities then
        ctx.entities = entities:GetFullName()
        local okc, kids = pcall(function() return entities:GetChildren() end)
        if okc and kids then ctx.entity_count = #kids end
    end

    -- 1) mode / difficulty from labels + attributes
    for _, e in ipairs(labels) do
        local t = e.text
        if #t <= 24 then
            local m = match_set(t, MODE_SET)
            if m and not ctx.mode then ctx.mode = m; ctx.sources.mode = e.path end
            local d = match_set(t, DIFF_SET)
            if d and not ctx.difficulty then ctx.difficulty = d; ctx.sources.difficulty = e.path end
        end
    end

    -- 2) wave counter
    local best_wave, best_score = nil, 0
    for _, e in ipairs(labels) do
        local t = e.text
        local a, b = string.match(t, "(%d+)%s*/%s*(%d+)")
        if not a then a, b = string.match(t, "(%d+)%s*of%s*(%d+)") end
        local tl = lower(t)
        if a then
            local score = 1
            if contains_any(tl, CLASS_KEYWORDS.wave) then score = 4 end
            if #t <= 16 then score = score + 1 end
            if score > best_score then
                best_score = score
                best_wave = { cur = tonumber(a), total = tonumber(b), path = e.path, text = t }
            end
        else
            local lone = string.match(t, "^(%d+)%s*$")
            if lone and contains_any(tl, { "wave", "round" }) then
                if best_score < 3 then
                    best_score = 3
                    best_wave = { cur = tonumber(lone), total = nil, path = e.path, text = t }
                end
            end
        end
    end
    if best_wave and not ctx.wave_cur then
        ctx.wave_cur   = best_wave.cur
        ctx.wave_total = best_wave.total
        ctx.sources.wave = best_wave.path
        ctx.wave_text = best_wave.text
    end

    -- attribute fallback when the counter is not on screen
    if not ctx.wave_cur then
        for _, k in ipairs({ "Wave", "CurrentWave", "WavesCleared" }) do
            local v, src = PROBE.attr(k)
            if type(v) == "number" then
                ctx.wave_cur = (k == "WavesCleared") and (v + 1) or v
                ctx.sources.wave = src
                break
            end
        end
    end

    -- 3) countdown label (pure number 1..120 sitting near a wave/start label)
    local cd, cd_path = nil, nil
    for _, e in ipairs(labels) do
        local t = string.match(e.text, "^(%d+)%s*$")
        if t then
            local v = tonumber(t)
            if v and v >= 1 and v <= 120 then
                if contains_any(e.path, CLASS_KEYWORDS.wave) or contains_any(e.path, CLASS_KEYWORDS.start)
                    or contains_any(e.text, CLASS_KEYWORDS.start) then
                    cd, cd_path = v, e.path
                end
            end
        end
        local inline = string.match(e.text, "(%d+)%s*$")
        if inline and contains_any(e.text, CLASS_KEYWORDS.start) then
            cd, cd_path = tonumber(inline), e.path
        end
    end
    ctx.countdown, ctx.sources.countdown = cd, cd_path

    -- 4) game speed
    for _, e in ipairs(labels) do
        local t = lower(e.text)
        if #t <= 6 and not ctx.speed then
            local v = string.match(t, "^x(%d)$") or string.match(t, "^(%d)x$")
            if v then
                ctx.speed = tonumber(v)
                ctx.sources.speed = e.path
            end
        end
    end
    if not ctx.speed then
        local attrs = { PROBE.attributes_of(Workspace), PROBE.attributes_of(ReplicatedStorage) }
        local rc = PROBE.run_context()
        if rc then table.insert(attrs, PROBE.attributes_of(rc)) end
        for _, a in ipairs(attrs) do
            for k, v in pairs(a) do
                local lk = lower(k)
                if type(v) == "number" and v >= 1 and v <= 10
                    and (string.find(lk, "speed", 1, true) or string.find(lk, "tick", 1, true)) then
                    ctx.speed = v
                    ctx.sources.speed = "attr:" .. k
                end
            end
        end
    end

    -- 5) map name
    local map_sources = {
        { inst = Workspace, key = { "Map", "MapName", "CurrentMap", "MapId" } },
        { inst = ReplicatedStorage, key = { "Map", "MapName", "CurrentMap", "MapId" } },
    }
    for _, src in ipairs(map_sources) do
        for _, k in ipairs(src.key) do
            local attr = PROBE.attributes_of(src.inst)[k]
            if type(attr) == "string" and attr ~= "" then
                ctx.map, ctx.sources.map = attr, "attr:" .. k
            end
            local ch = src.inst:FindFirstChild(k)
            if not ctx.map and ch and ch:IsA("StringValue") and type(ch.Value) == "string" and ch.Value ~= "" then
                ctx.map, ctx.sources.map = ch.Value, ch:GetFullName()
            end
        end
    end
    if not ctx.map then
        for _, e in ipairs(labels) do
            local t = e.text
            if #t <= 30 then
                local v = string.match(t, "^[Mm]ap%s*:?%s*(.+)$")
                if v and v ~= "" then ctx.map, ctx.sources.map = v, e.path end
            end
        end
    end
    -- map folder heuristic: a workspace folder holding spawn/path markers
    if not ctx.map then
        local ok, kids = pcall(function() return Workspace:GetChildren() end)
        if ok and kids then
            for _, c in ipairs(kids) do
                if c:IsA("Folder") or c:IsA("Model") then
                    local hit = 0
                    local okc, cc = pcall(function() return c:GetChildren() end)
                    if okc and cc then
                        for _, x in ipairs(cc) do
                            local n = lower(x.Name)
                            if string.find(n, "spawn", 1, true) or string.find(n, "path", 1, true)
                                or string.find(n, "waypoint", 1, true) or string.find(n, "base", 1, true) then
                                hit = hit + 1
                            end
                        end
                    end
                    if hit >= 2 then
                        ctx.map, ctx.sources.map = c.Name, c:GetFullName()
                        break
                    end
                end
            end
        end
    end

    -- 6) seeds / currency
    for _, e in ipairs(labels) do
        local t, _ = string.gsub(e.text, ",", "")
        local v = string.match(t, "(%d+)")
        if v and contains_any(e.text, CLASS_KEYWORDS.seed) and #e.text <= 20 then
            ctx.seeds, ctx.sources.seeds = tonumber(v), e.path
        end
    end

    -- 7) manual overrides win, they were set by the operator when autopick was wrong
    local ov = STORE.profile.overrides or {}
    for k, v in pairs(ov) do
        if v ~= nil and v ~= "" then
            ctx[k] = v
            ctx.sources[k] = "override"
        end
    end

    ctx.map_label = ctx.map or ("map#" .. tostring(ctx.map_sig))
    return ctx, { labels = labels, sig_parts = parts }
end

--==============================================================================
-- loadout scan  (what units are equipped / in use)
--==============================================================================

function PROBE.loadout()
    local units, src = {}, nil

    -- a) attributes on LocalPlayer / in ReplicatedStorage mentioning equipped units
    local tries = {
        { inst = LP, keys = { "EquippedUnit", "EquippedUnits", "Loadout", "Units", "SelectedUnit" } },
        { inst = ReplicatedStorage, keys = { "EquippedUnit", "EquippedUnits", "Loadout", "Units" } },
    }
    for _, t in ipairs(tries) do
        if t.inst then
            local attrs = PROBE.attributes_of(t.inst)
            for _, k in ipairs(t.keys) do
                local v = attrs[k]
                if type(v) == "string" and v ~= "" then
                    for u in string.gmatch(v, "[^,;|]+") do
                        local trim = string.match(u, "^%s*(.-)%s*$")
                        if trim and trim ~= "" then units[#units + 1] = trim end
                    end
                    src = "attr:" .. k
                end
            end
        end
    end

    -- b) gui slots: anything that names a unit and is not a plain menu button
    if #units == 0 then
        local seen = {}
        for _, e in ipairs(PROBE.labels()) do
            local p = lower(e.path)
            if contains_any(p, { "loadout", "equipped", "unit", "slot", "hotbar", "inventory" }) then
                local t = string.match(e.text, "^%s*(.-)%s*$")
                if t and #t >= 2 and #t <= 24 and not string.match(t, "^%d+$") then
                    local key = lower(t)
                    if not seen[key] then
                        seen[key] = true
                        units[#units + 1] = t
                    end
                end
            end
        end
        if #units > 0 then src = "gui-labels" end
    end

    return units, src
end

--==============================================================================
-- container discovery  (where placed units and enemies live)
--==============================================================================

function PROBE.watch_added(duration, cb)
    local added = {}
    local conns = {}
    local function on_added(inst)
        added[#added + 1] = inst
    end
    table.insert(conns, Workspace.DescendantAdded:Connect(on_added))

    task.delay(duration, function()
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        if cb then cb(added) end
    end)
    return conns
end

-- from a list of freshly added instances, guess the placed-unit model
function PROBE.pick_unit(list)
    local best, best_score = nil, -1
    for _, inst in ipairs(list) do
        if inst:IsA("Model") or inst:IsA("MeshPart") or inst:IsA("Part") then
            local parent = inst.Parent
            local pname = parent and (parent.Name or "") or ""
            local score = 0
            if contains_any(pname, CLASS_KEYWORDS.unit) then score = score + 3 end
            -- a numeric ID attribute is the server's own handle for a placed unit
            if PROBE.entity_id(inst) then score = score + 5 end
            -- enemies appear in the same folder: never mistake one for a tower
            if PROBE.is_enemy(inst) then score = score - 12 end
            if parent and parent.Parent then
                local gp = parent.Parent
                local gpname = gp.Name or ""
                if contains_any(gpname, CLASS_KEYWORDS.unit) then score = score + 2 end
            end
            if inst:IsA("Model") then score = score + 1 end
            local ok, hashumanoid = pcall(function() return inst:FindFirstChildOfClass("Humanoid") ~= nil end)
            if ok and hashumanoid then score = score - 2 end
            if score > best_score then best, best_score = inst, score end
        end
    end
    if not best then return nil end
    local container = best.Parent
    return {
        inst = best,
        id = PROBE.entity_id(best),
        name = best.Name,
        path = best:GetFullName(),
        container = container and container:GetFullName() or nil,
        class = best.ClassName,
        score = best_score,
    }
end

function PROBE.count_in_container(container)
    if not container then return 0 end
    local ok, kids = pcall(function() return container:GetChildren() end)
    if ok and kids then return #kids end
    return 0
end

--==============================================================================
-- remote scan + optional spy
--==============================================================================

function PROBE.scan_remotes()
    local out = {}
    local roots = { ReplicatedStorage, Workspace }
    for _, r in ipairs(roots) do
        local ok, list = pcall(function() return r:GetDescendants() end)
        if ok and list then
            for _, d in ipairs(list) do
                if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
                    local n = lower(d.Name)
                    local score = 0
                    for _, k in ipairs(CLASS_KEYWORDS.wave) do
                        if string.find(n, k, 1, true) then score = score + 3 end
                    end
                    for _, k in ipairs(CLASS_KEYWORDS.start) do
                        if string.find(n, k, 1, true) then score = score + 2 end
                    end
                    for _, k in ipairs(CLASS_KEYWORDS.unit) do
                        if string.find(n, k, 1, true) then score = score + 1 end
                    end
                    out[#out + 1] = { name = d.Name, class = d.ClassName, path = d:GetFullName(), score = score }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end

function PROBE.install_spy()
    if not PROBE.spy_supported then return false, "hookmetamethod not available on this executor" end
    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        local oldindex = mt.__index
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method == "FireServer" or method == "InvokeServer" then
                if typeof(self) == "Instance" then
                    local entry = PROBE.spy_log[self.Name]
                    if not entry then
                        entry = { count = 0, samples = {}, class = self.ClassName, path = self:GetFullName() }
                        PROBE.spy_log[self.Name] = entry
                    end
                    entry.count = entry.count + 1
                    if #entry.samples < 5 then
                        local args = { ... }
                        local preview = {}
                        for i = 1, math.min(#args, 6) do
                            local a = args[i]
                            local ta = typeof(a)
                            if ta == "Instance" then
                                preview[i] = "<" .. a.ClassName .. ":" .. a.Name .. ">"
                            elseif ta == "number" or ta == "string" or ta == "boolean" then
                                preview[i] = tostring(a)
                            else
                                preview[i] = ta
                            end
                        end
                        entry.samples[#entry.samples + 1] = table.concat(preview, ", ")
                    end
                end
            end
            return old(self, ...)
        end)
        if oldindex then
            setreadonly(mt, true)
        else
            setreadonly(mt, true)
        end
    end)
    if ok then return true end
    return false, tostring(err)
end

--==============================================================================
-- live wave-state reader + T0 anchoring
--==============================================================================

-- full read: label scan + heuristics, use sparingly (it walks the whole gui)
function PROBE.wave_state()
    local st = { cur = nil, total = nil, countdown = nil, src = nil }

    local pinned = STORE.profile.wave_path
    if pinned then
        local obj = resolve_path(pinned)
        if obj and obj.Text then
            local a, b = string.match(obj.Text, "(%d+)%s*/%s*(%d+)")
            if a then
                st.cur, st.total, st.src = tonumber(a), tonumber(b), pinned
            else
                local lone = string.match(obj.Text, "^(%d+)%s*$")
                if lone then st.cur, st.src = tonumber(lone), pinned end
            end
        end
    end

    if not st.cur then
        local ctx = PROBE.detect_context()
        st.cur, st.total = ctx.wave_cur, ctx.wave_total
        st.src = ctx.sources.wave
        st.countdown = ctx.countdown
        st.t = U.now()
    else
        -- still need the countdown, but only pay for the scan when pinned parse worked
        local ctx = PROBE.detect_context()
        st.countdown = ctx.countdown
        st.t = U.now()
    end
    PROBE._cache = st
    return st
end

-- cheap read used by the 10 Hz watcher: pinned path first, full scan at most every 1.2 s
function PROBE.wave_state_cheap()
    local pinned = STORE.profile.wave_path
    if pinned then
        local obj = resolve_path(pinned)
        if obj and obj.Text then
            local st = { cur = nil, total = nil, countdown = nil, src = pinned }
            local a, b = string.match(obj.Text, "(%d+)%s*/%s*(%d+)")
            if a then
                st.cur, st.total = tonumber(a), tonumber(b)
            else
                local lone = string.match(obj.Text, "^(%d+)%s*$")
                if lone then st.cur = tonumber(lone) end
            end
            local c = PROBE._cache
            if c and c.t and (U.now() - c.t) < 1.5 then
                st.countdown = c.countdown
            end
            return st
        end
    end

    local c = PROBE._cache
    if not c or not c.t or (U.now() - c.t) > 1.2 then
        return PROBE.wave_state()
    end
    return c
end
--==============================================================================
-- [3] ENGINE — recorder + wave-synced replay
--==============================================================================

local REC = {}
local PLAY = {}

local S = {
    recording   = false,
    playing     = false,
    steps       = {},
    rec_start   = 0,
    wave        = nil,
    wave_total  = nil,
    wave_t0     = nil,
    wave_prev   = { cd = nil, cur = nil },
    ctx         = nil,
    anchors     = {},
    last_ctx    = nil,
    play_start  = 0,
    stop_requested = false,
    stat        = {},
    last_down   = nil,
    down_since  = nil,
    last_move   = 0,
}

local STATE = S   -- exported through getgenv()

--==============================================================================
-- capability probe — never assume the executor has what we want
--==============================================================================

local CAP = {
    vim       = VIM ~= nil,
    touch     = false,
    vim_move  = false,
    vim_btn   = false,
    vim_key   = false,
    mouse_lib = (type(mousemoveabs) == "function") and (type(mouse1click) == "function") and (type(mouse1press) == "function"),
    firesignal= (type(firesignal) == "function"),
    getconn   = (type(getconnections) == "function"),
}

if VIM then
    CAP.touch    = pcall(function() return VIM.SendTouchEvent end)
    CAP.vim_move = pcall(function() return VIM.SendMouseMoveEvent end)
    CAP.vim_btn  = pcall(function() return VIM.SendMouseButtonEvent end)
    CAP.vim_key  = pcall(function() return VIM.SendKeyEvent end)
end

local RS_EXCLUDE
do
    local ok = pcall(function() RS_EXCLUDE = Enum.RaycastFilterType.Exclude end)
    if not ok then RS_EXCLUDE = Enum.RaycastFilterType.Blacklist end
end

--==============================================================================
-- coordinate / raycast helpers
--==============================================================================

local function to_input_space(x, y)
    return x + (CONFIG.tap_offset_x or 0), y + (CONFIG.tap_offset_y or 0)
end

function REC.raycast_world(x, y)
    if not CAM then return nil end
    local ok, ray = pcall(function() return CAM:ViewportPointToRay(x, y) end)
    if not ok or not ray then return nil end
    local params = RaycastParams.new()
    params.FilterType = RS_EXCLUDE
    local filter = {}
    if LP and LP.Character then filter[#filter + 1] = LP.Character end
    params.FilterDescendantsInstances = filter
    params.IgnoreWater = true
    local ok2, res = pcall(function() return Workspace:Raycast(ray.Origin, ray.Direction * 1200, params) end)
    if ok2 and res then
        return {
            x = res.Position.X, y = res.Position.Y, z = res.Position.Z,
            part = res.Instance and res.Instance:GetFullName() or nil,
            part_name = res.Instance and res.Instance.Name or nil,
        }
    end
    return nil
end

-- deepest visible GuiObject under a point, as a full path string
function REC.gui_at(x, y)
    local best, best_area = nil, math.huge
    for _, root in ipairs(PROBE.gui_roots()) do
        local ok, list = pcall(function() return root:GetDescendants() end)
        if ok and list then
            for _, d in ipairs(list) do
                if d:IsA("GuiObject") and d.Visible then
                    local okp, ap, as = pcall(function() return d.AbsolutePosition, d.AbsoluteSize end)
                    if okp and ap and as and as.X > 0 and as.Y > 0 then
                        if x >= ap.X and x <= ap.X + as.X and y >= ap.Y and y <= ap.Y + as.Y then
                            local area = as.X * as.Y
                            if area <= best_area then
                                best, best_area = d, area
                            end
                        end
                    end
                end
            end
        end
    end
    if best then
        return best:GetFullName(), best
    end
    return nil, nil
end

--==============================================================================
-- input simulation
--==============================================================================

local TOUCH_ID = 7

local function sim_move(x, y)
    if CAP.vim and CAP.vim_move then
        pcall(function() VIM:SendMouseMoveEvent(x, y, nil) end)
        return true
    end
    if CAP.mouse_lib then
        pcall(mousemoveabs, x, y)
        return true
    end
    return false
end

local function sim_mouse_down(x, y)
    if CAP.vim and CAP.vim_btn then
        pcall(function() VIM:SendMouseButtonEvent(math.floor(x), math.floor(y), 0, true, game, 1) end)
        return true
    end
    if CAP.mouse_lib then
        pcall(mousemoveabs, x, y)
        pcall(mouse1press)
        return true
    end
    return false
end

local function sim_mouse_up(x, y)
    if CAP.vim and CAP.vim_btn then
        pcall(function() VIM:SendMouseButtonEvent(math.floor(x), math.floor(y), 0, false, game, 1) end)
        return true
    end
    if CAP.mouse_lib then
        pcall(mousemoveabs, x, y)
        pcall(mouse1release)
        return true
    end
    return false
end

local function sim_touch(state, x, y)
    if not (CAP.vim and CAP.touch) then return false end
    local st
    if state == "begin" then st = Enum.UserInputState.Begin
    elseif state == "change" then st = Enum.UserInputState.Change
    else st = Enum.UserInputState.End end
    return pcall(function() VIM:SendTouchEvent(TOUCH_ID, st.Value, x, y) end)
end

-- fire a gui button without touching the mouse at all (most robust path)
local function ui_fire(obj)
    if not obj then return false end
    if not obj:IsA("GuiButton") then return false end
    local fired = false
    if CAP.firesignal then
        pcall(function() firesignal(obj.MouseButton1Click) end)
        pcall(function() firesignal(obj.Activated) end)
        pcall(function() firesignal(obj.MouseButton1Down) end)
        pcall(function() firesignal(obj.MouseButton1Up) end)
        fired = true
    elseif CAP.getconn then
        local ok, conns = pcall(function() return getconnections(obj.Activated) end)
        if ok and conns then
            for _, c in ipairs(conns) do
                local okf = pcall(function() c.Function() end)
                if not okf then pcall(function() c:Fire() end) end
            end
            fired = true
        end
    end
    return fired
end

--==============================================================================
-- dispatch one recorded step
--==============================================================================

local function resolve_target(step)
    local x, y = step.x, step.y
    local mode = CONFIG.click_mode

    -- a) follow the live gui element if we recorded one
    if (mode == "auto" or mode == "ui" or mode == "mouse" or mode == "touch") and step.ui and CONFIG.follow_ui then
        local obj = resolve_path(step.ui)
        if obj and obj:IsA("GuiObject") and obj.Visible then
            local ok, ap, as = pcall(function() return obj.AbsolutePosition, obj.AbsoluteSize end)
            if ok and ap and as and as.X > 0 and as.Y > 0 then
                x = ap.X + as.X / 2
                y = ap.Y + as.Y / 2
                if CONFIG.jitter_pos > 0 then
                    x = x + U.rand(-math.min(CONFIG.jitter_pos, as.X * 0.3), math.min(CONFIG.jitter_pos, as.X * 0.3))
                    y = y + U.rand(-math.min(CONFIG.jitter_pos, as.Y * 0.3), math.min(CONFIG.jitter_pos, as.Y * 0.3))
                end
                return x, y, obj
            end
        end
    end

    -- b) follow the world point (camera independent)
    if step.world and not step.ui and CONFIG.follow_world then
        local ok, sp, onscreen = pcall(function()
            local v, vis = CAM:WorldToScreenPoint(Vector3.new(step.world.x, step.world.y, step.world.z))
            return v, vis
        end)
        if ok and sp and onscreen then
            x, y = sp.X, sp.Y
        end
    end

    if CONFIG.jitter_pos > 0 then
        x = x + U.rand(-CONFIG.jitter_pos, CONFIG.jitter_pos)
        y = y + U.rand(-CONFIG.jitter_pos, CONFIG.jitter_pos)
    end
    return x, y, nil
end

local function dispatch(step)
    if step.kind == "key" then
        if CAP.vim and CAP.vim_key then
            local kc = Enum.KeyCode[step.code] or Enum.KeyCode.Unknown
            pcall(function() VIM:SendKeyEvent(step.pressed and true or false, kc, false, nil) end)
            return true
        end
        return false
    end

    local x, y, obj = resolve_target(step)

    if CONFIG.click_mode == "ui" and obj then
        return ui_fire(obj)
    end

    if CONFIG.click_mode == "auto" and obj and step.kind == "up" then
        -- auto: for button taps prefer the direct gui fire, it survives resolution changes
        local mark = obj:IsA("GuiButton")
        if mark then
            local ok = ui_fire(obj)
            if ok then return true end
        end
    end

    x, y = to_input_space(x, y)

    if step.kind == "down" then
        if step.itype == "Touch" and CAP.touch then
            return sim_touch("begin", x, y)
        end
        return sim_mouse_down(x, y)
    elseif step.kind == "up" then
        if step.itype == "Touch" and CAP.touch then
            return sim_touch("end", x, y)
        end
        return sim_mouse_up(x, y)
    elseif step.kind == "move" then
        if step.itype == "Touch" and CAP.touch then
            return sim_touch("change", x, y)
        end
        return sim_move(x, y)
    end
    return false
end

--==============================================================================
-- recorder
--==============================================================================

local rec_conns = {}
local moves_recent = {}

local function own_gui_hit(x, y)
    if UI_API and UI_API.contains_point then
        return UI_API.contains_point(x, y)
    end
    return false
end

local function push_step(step)
    if #S.steps >= CONFIG.max_steps then
        S.recording = false
        U.notify("ANON GTD", "Step limit reached (" .. CONFIG.max_steps .. "), recording stopped")
        return
    end
    step.wave = S.wave
    step.dt = S.wave_t0 and (U.now() - S.wave_t0) or nil
    step.t_abs = U.now() - S.rec_start
    table.insert(S.steps, step)
    if S.counters then
        S.counters.recorded = S.counters.recorded + 1
        if step.kind == "move" then S.counters.moves = S.counters.moves + 1 end
        if step.kind == "key" then S.counters.keys = S.counters.keys + 1 end
    end
    if UI_API and UI_API.live_step then UI_API.live_step(step, #S.steps) end
end

local function flush_recent_moves(cutoff, cur_x, cur_y)
    local kept = {}
    for _, m in ipairs(moves_recent) do
        if m.t >= cutoff then
            if math.abs(m.x - cur_x) > 3 or math.abs(m.y - cur_y) > 3 then
                table.insert(kept, m)
            end
        end
    end
    moves_recent = kept
    for _, m in ipairs(kept) do
        push_step({ kind = "move", x = m.x, y = m.y, itype = m.itype or "MouseMovement" })
    end
end

local function attribute_tower(step)
    local container_hint = S.anchors.container_path or STORE.profile.container_path
    local before = 0
    if container_hint then
        before = PROBE.count_in_container(resolve_path(container_hint))
    end

    PROBE.watch_added(CONFIG.verify_timeout, function(list)
        local u = PROBE.pick_unit(list)
        if u then
            step.tower = u.name
            step.tower_id = u.id
            step.tower_path = u.path
            step.tower_class = u.class
            if u.container then
                step.container = u.container
                S.anchors.container_path = u.container
            end
            if UI_API and UI_API.toast then UI_API.toast("placed: " .. tostring(u.name)) end
        else
            step.tower = nil
            step.unverified = true
        end
    end)
end

local function on_began(input, gp)
    if not S.recording then return end
    local ut = input.UserInputType
    local x, y = input.Position.X, input.Position.Y

    if S.counters then S.counters.began = S.counters.began + 1 end

    if own_gui_hit(x, y) then
        if S.counters then S.counters.own_ui = S.counters.own_ui + 1 end
        return
    end

    if ut == Enum.UserInputType.Touch
        or ut == Enum.UserInputType.MouseButton1
        or ut == Enum.UserInputType.MouseButton2 then
        flush_recent_moves(U.now() - 0.35, x, y)
        local uipath = REC.gui_at(x, y)
        local step = {
            kind = "down",
            x = x, y = y,
            itype = ut.Name,
            button = (ut == Enum.UserInputType.MouseButton2) and 1 or 0,
            ui = uipath,
            world = REC.raycast_world(x, y),
        }
        push_step(step)
        S.last_down = step
        S.down_since = U.now()
    elseif ut == Enum.UserInputType.Keyboard then
        push_step({ kind = "key", code = input.KeyCode.Name, pressed = true, x = x, y = y, itype = "Key" })
    end
end

local function on_changed(input, gp)
    if not S.recording then return end
    local ut = input.UserInputType
    local x, y = input.Position.X, input.Position.Y
    if own_gui_hit(x, y) then return end

    local is_dragging = S.down_since ~= nil and (U.now() - S.down_since) < 3
    if is_dragging and (ut == Enum.UserInputType.Touch or ut == Enum.UserInputType.MouseMovement) then
        if U.now() - S.last_move > 0.06 then
            S.last_move = U.now()
            push_step({ kind = "move", x = x, y = y, itype = ut.Name })
        end
    else
        moves_recent[#moves_recent + 1] = { t = U.now(), x = x, y = y, itype = ut.Name }
        if #moves_recent > 24 then table.remove(moves_recent, 1) end
    end
end

local function on_ended(input, gp)
    if not S.recording then return end
    local ut = input.UserInputType
    local x, y = input.Position.X, input.Position.Y
    if S.counters then S.counters.ended = S.counters.ended + 1 end

    if ut == Enum.UserInputType.Touch
        or ut == Enum.UserInputType.MouseButton1
        or ut == Enum.UserInputType.MouseButton2 then
        if own_gui_hit(x, y) then
            if S.counters then S.counters.own_ui = S.counters.own_ui + 1 end
            return
        end
        local step = {
            kind = "up",
            x = x, y = y,
            itype = ut.Name,
            button = (ut == Enum.UserInputType.MouseButton2) and 1 or 0,
            ui = REC.gui_at(x, y),
            world = REC.raycast_world(x, y),
        }
        push_step(step)
        S.last_down = nil
        S.down_since = nil
        if step.world then
            attribute_tower(step)
        end
    elseif ut == Enum.UserInputType.Keyboard then
        push_step({ kind = "key", code = input.KeyCode.Name, pressed = false, x = x, y = y, itype = "Key" })
    end
end

--------------------------------------------------------------------------------
-- wave watcher: turns the game's own counters into T0 events
--------------------------------------------------------------------------------

local wave_thread_running = false

local function wave_loop()
    if wave_thread_running then return end
    wave_thread_running = true
    while S.recording or S.playing do
        -- a new run carries its own unix start time: the cleanest "wave 1 just began"
        -- signal available, and it comes from the server rather than from a label
        local gst = PROBE.attr("GameStartTime")
        if type(gst) == "number" and gst > 0 then
            if type(S.last_game_start) == "number" and gst > S.last_game_start then
                S.wave = 1
                S.wave_t0 = U.now()
                S.wave_prev = { cd = nil, cur = 1 }
                S.run_started_at = gst
                -- the label can still show the previous run for a moment: trust the
                -- server's start time over it for a few seconds
                S.anchor_grace_until = U.now() + 4
                if UI_API and UI_API.toast then
                    UI_API.toast("new run · wave 1 anchored (GameStartTime)")
                end
                PLAY.on_wave_start(1)
            end
            S.last_game_start = gst
            S.run_elapsed = math.max(0, os.time() - gst)
        end

        local st = PROBE.wave_state_cheap()
        local started = false

        local in_grace = S.anchor_grace_until and U.now() < S.anchor_grace_until

        if st.cur ~= nil and not in_grace then
            if S.wave ~= nil and st.cur ~= S.wave then
                started = true
            end
            S.wave = st.cur
        end
        if st.total then S.wave_total = st.total end

        if st.countdown then
            if S.wave_prev.cd and S.wave_prev.cd <= 1 and st.countdown >= 3 then
                started = true
            end
            S.wave_prev.cd = st.countdown
        end

        if st.src then S.anchors.wave_path = st.src end

        if started or S.wave_t0 == nil then
            S.wave_t0 = U.now()
            if started then
                if UI_API and UI_API.status then UI_API.status() end
                PLAY.on_wave_start(S.wave)
            end
        end

        task.wait(0.1)
    end
    wave_thread_running = false
end

function REC.start()
    if S.recording then return false, "already recording" end
    if S.playing then return false, "stop playback first" end

    local ctx = PROBE.detect_context()
    S.ctx = ctx
    S.last_ctx = ctx
    S.steps = {}
    S.rec_start = U.now()
    S.wave_t0 = nil
    S.wave_prev = { cd = nil, cur = nil }
    S.anchors = {}
    S.recording = true
    S.wave = ctx.wave_cur
    S.wave_total = ctx.wave_total
    S.ctx.start_wave = ctx.wave_cur
    S.ctx.loadout, S.ctx.loadout_src = PROBE.loadout()

    -- counters so a "recorded but nothing showed up" report can be answered with
    -- numbers instead of guesses
    S.counters = { began = 0, own_ui = 0, recorded = 0, moves = 0, keys = 0, ended = 0 }
    REC.last_report = nil

    rec_conns = {}
    table.insert(rec_conns, UIS.InputBegan:Connect(on_began))
    table.insert(rec_conns, UIS.InputChanged:Connect(on_changed))
    table.insert(rec_conns, UIS.InputEnded:Connect(on_ended))

    if CONFIG.scan_labels then
        U.spawn(wave_loop)
    end

    if PROBE.spy_supported then
        local ok, err = PROBE.install_spy()
        if not ok then warn("[ANON GTD] remote spy off: " .. tostring(err)) end
    end

    U.notify("ANON GTD", "Recording · " .. tostring(ctx.mode or "?") .. " · " .. tostring(ctx.difficulty or "?")
        .. " · " .. tostring(ctx.map_label or "?") .. " · x" .. tostring(ctx.speed or "?")
        .. " · tap STOP (top-left) when done", 8)

    -- fold the panel away: on a phone it covers a big part of the screen and those
    -- taps are deliberately not recorded
    if CONFIG.auto_collapse_on_record and UI_API.collapse then
        pcall(UI_API.collapse)
    end

    if UI_API and UI_API.status then UI_API.status() end
    return true
end

function REC.counters()
    return S.counters or {}
end

function REC.finalize(name, pinned)
    for _, c in ipairs(rec_conns) do pcall(function() c:Disconnect() end) end
    rec_conns = {}
    S.recording = false

    if #S.steps == 0 then
        local c = S.counters or {}
        local why
        if (c.own_ui or 0) > 0 then
            why = "the panel was in the way — those taps are ignored on purpose; keep it collapsed (STOP pill only) and tap the game"
        elseif (c.began or 0) == 0 then
            why = "input never reached the listener (executor attached to the wrong client?)"
        else
            why = "taps were seen but nothing was usable"
        end
        local reason = string.format("nothing recorded · taps seen %d · skipped over our panel %d · %s",
            c.began or 0, c.own_ui or 0, why)
        REC.last_report = reason
        return nil, reason
    end

    local macro = {
        id       = STORE.new_id(),
        name     = name or ("rec " .. U.fmt_date(os.time())),
        pinned   = pinned and true or false,
        created  = os.time(),
        duration = U.now() - S.rec_start,
        ctx      = S.ctx,
        steps    = S.steps,
        anchors  = S.anchors,
        version  = CONFIG.version,
        engine   = { speed_mode = CONFIG.speed_mode, jitter_pos = CONFIG.jitter_pos },
    }

    -- context stamp: what makes this macro unique in history
    macro.ctx.map_label  = macro.ctx.map_label or ("map#" .. tostring(macro.ctx.map_sig))
    macro.ctx.wave_total = macro.ctx.wave_total or S.wave_total
    macro.ctx.step_count = #S.steps
    macro.ctx.unit_names = {}
    local seen = {}
    for _, st in ipairs(S.steps) do
        if st.tower and not seen[st.tower] then
            seen[st.tower] = true
            table.insert(macro.ctx.unit_names, st.tower)
        end
    end

    if STORE.profile.wave_path == nil and S.anchors.wave_path then
        STORE.profile.wave_path = S.anchors.wave_path
        STORE.save_profile()
    end
    if STORE.profile.container_path == nil and S.anchors.container_path then
        STORE.profile.container_path = S.anchors.container_path
        STORE.save_profile()
    end

    local ok, err = STORE.save_macro(macro)
    local c = S.counters or {}
    local diag = STORE.diagnose()
    local storage = ok and (err or "disk") or ("FAILED: " .. tostring(err))
    local report = string.format(
        "%s · %d steps (moves %d, keys %d) · taps seen %d · skipped over panel %d · storage %s · %s",
        tostring(macro.name), #macro.steps, c.moves or 0, c.keys or 0,
        c.began or 0, c.own_ui or 0, storage, (diag:gsub("\n", " · ")))
    REC.last_report = report

    if not ok then return nil, err end
    U.notify("ANON GTD", "Saved: " .. tostring(macro.name) .. " (" .. #macro.steps .. " steps)"
        .. (err and (" · " .. tostring(err)) or ""), 6)
    return macro, err, report
end

function REC.discard()
    for _, c in ipairs(rec_conns) do pcall(function() c:Disconnect() end) end
    rec_conns = {}
    S.recording = false
    S.steps = {}
    if UI_API and UI_API.status then UI_API.status() end
end

function REC.step_count()
    return #S.steps
end

function REC.elapsed()
    if not S.recording then return 0 end
    return U.now() - S.rec_start
end

--==============================================================================
-- player — wave-synced replay
--==============================================================================

function PLAY.on_wave_start(wave)
    S.stat.last_wave = wave
    if UI_API and UI_API.status then UI_API.status() end
end

function PLAY.compat(macro)
    local cur = PROBE.detect_context()
    S.last_ctx = cur
    local out = {}
    local c = macro.ctx or {}
    if c.place_id and c.place_id ~= game.PlaceId then
        out[#out + 1] = "place " .. tostring(c.place_id) .. " -> " .. tostring(game.PlaceId)
    end
    if c.mode and cur.mode and c.mode ~= cur.mode then
        out[#out + 1] = "mode " .. c.mode .. " -> " .. cur.mode
    end
    if c.difficulty and cur.difficulty and c.difficulty ~= cur.difficulty then
        out[#out + 1] = "difficulty " .. c.difficulty .. " -> " .. cur.difficulty
    end
    if c.map_sig and cur.map_sig and c.map_sig ~= cur.map_sig then
        out[#out + 1] = "map " .. tostring(c.map_label) .. " -> " .. tostring(cur.map_label)
    end
    if c.speed and cur.speed and c.speed ~= cur.speed then
        out[#out + 1] = "speed x" .. tostring(c.speed) .. " -> x" .. tostring(cur.speed)
    end
    if c.wave_total and cur.wave_total and c.wave_total ~= cur.wave_total then
        out[#out + 1] = "wave total " .. tostring(c.wave_total) .. " -> " .. tostring(cur.wave_total)
    end
    if c.loadout and #c.loadout > 0 then
        local have = {}
        for _, u in ipairs(cur.loadout or {}) do have[string.lower(u)] = true end
        local missing = {}
        for _, u in ipairs(c.loadout) do
            if not have[string.lower(u)] then missing[#missing + 1] = u end
        end
        if #missing > 0 then
            out[#out + 1] = "loadout differs (" .. table.concat(missing, ", ") .. ")"
        end
    end
    return out, cur
end

local function wait_until(target)
    local guard = 0
    while true do
        if S.stop_requested then return false end
        local left = target - U.now()
        if left <= 0 then break end
        if left > 0.05 then
            task.wait(0.02)
        else
            task.wait(left)
        end
        guard = guard + 1
        if guard > 200000 then break end
    end
    return true
end

local function container_count(path)
    local c = path and resolve_path(path)
    if not c then return nil end
    return PROBE.count_in_container(c)
end

local function wait_for_wave(wave)
    if not wave then return true end
    local deadline = U.now() + CONFIG.wave_timeout
    while S.wave ~= nil and wave > S.wave do
        if S.stop_requested then return false end
        if U.now() > deadline then return false, "wave timeout" end
        task.wait(0.05)
    end
    return true
end

-- wait for the round to reach the wave this macro was recorded on:
--  * already past it  -> wait for the counter to drop back (a fresh round)
--  * not there yet    -> wait for the counter to climb to it
local function align_to_start_wave(macro, opts)
    local start_wave = (macro.ctx and macro.ctx.start_wave)
    if not start_wave or not S.wave then return end

    if S.wave > start_wave and opts.wait_restart ~= false then
        local deadline = U.now() + (opts.restart_timeout or 900)
        U.notify("ANON GTD", "waiting for a fresh round (macro starts on wave " .. tostring(start_wave) .. ")")
        while S.wave and S.wave > start_wave do
            if S.stop_requested or U.now() > deadline then break end
            task.wait(0.25)
        end
    elseif S.wave < start_wave then
        local deadline = U.now() + (opts.align_timeout or 900)
        while S.wave and S.wave < start_wave do
            if S.stop_requested or U.now() > deadline then break end
            task.wait(0.25)
        end
    end
end

local function play_once(macro, scale, opts)
    S.play_start = U.now()
    local steps = macro.steps
    local placed_path = macro.anchors and macro.anchors.container_path or STORE.profile.container_path
    local pending_place = nil

    local i = 1
    while i <= #steps do
        if S.stop_requested then return "stopped" end
        local step = steps[i]
        S.stat.step = i
        S.stat.total = #steps

        local skip_step = false

        -- wave gate
        if step.wave and S.wave ~= nil then
            if S.wave > step.wave then
                S.stat.missed = (S.stat.missed or 0) + 1
            else
                local ok, why = wait_for_wave(step.wave)
                if not ok then
                    S.stat.timeouts = (S.stat.timeouts or 0) + 1
                    if why == "wave timeout" and CONFIG.skip_on_wave_timeout then
                        -- never tap at the wrong moment: drop the step instead
                        S.stat.skipped = (S.stat.skipped or 0) + 1
                        if UI_API and UI_API.toast then
                            UI_API.toast("wave " .. tostring(step.wave) .. " never came · step skipped")
                        end
                        skip_step = true
                    end
                end
            end
        end

        if not skip_step then

        -- time gate: dt inside the wave when possible, absolute otherwise
        local target
        if step.wave and S.wave_t0 and S.wave == step.wave and step.dt then
            target = S.wave_t0 + step.dt * scale
        else
            target = S.play_start + (step.t_abs or 0) * scale
        end
        target = target + U.rand(-CONFIG.jitter_time, CONFIG.jitter_time)
        if not wait_until(target) then return "stopped" end
        if U.now() > target + 2 then S.stat.late = (S.stat.late or 0) + 1 end

        local ok = dispatch(step)

        if step.kind == "down" then
            pending_place = step
        elseif step.kind == "up" then
            if pending_place and (pending_place.world or step.world) and placed_path then
                local before = container_count(placed_path)
                local tries = 0
                local landed = false
                while tries <= CONFIG.retries do
                    if before ~= nil then
                        local deadline = U.now() + CONFIG.verify_timeout
                        while U.now() < deadline do
                            local nowc = container_count(placed_path)
                            if nowc and nowc > before then landed = true; break end
                            task.wait(0.08)
                        end
                    else
                        landed = true
                    end
                    if landed then break end
                    tries = tries + 1
                    if tries <= CONFIG.retries then
                        dispatch(pending_place)
                        task.wait(0.12)
                        dispatch(step)
                    end
                end
                if landed then
                    S.stat.verified = (S.stat.verified or 0) + 1
                else
                    S.stat.failed = (S.stat.failed or 0) + 1
                end
            end
            pending_place = nil
            if UI_API and UI_API.status then UI_API.status() end
        end

        end -- skip_step

        i = i + 1
    end
    return "done"
end

function PLAY.run(macro, opts)
    opts = opts or {}
    if S.playing then return false, "already playing" end
    if S.recording then return false, "stop recording first" end

    local mismatches, cur = PLAY.compat(macro)

    -- never align on a stale counter: the watcher may have been idle
    if cur and cur.wave_cur then S.wave = cur.wave_cur end
    if cur and cur.wave_total then S.wave_total = cur.wave_total end
    local rec_speed = (macro.ctx and macro.ctx.speed) or cur.speed or 1
    local now_speed = cur.speed or 1
    local scale = 1
    if now_speed ~= rec_speed then
        if CONFIG.speed_mode == "block" and not opts.force then
            return false, string.format("speed x%s recorded, x%s now (speed_mode=block)", tostring(rec_speed), tostring(now_speed))
        end
        scale = rec_speed / now_speed
    end

    S.playing = true
    S.stop_requested = false
    S.stat = { step = 0, total = #macro.steps, late = 0, missed = 0, verified = 0, failed = 0, timeouts = 0, skipped = 0, last_wave = S.wave }

    -- the watcher also has to run while playing, not just while recording:
    -- without it S.wave freezes on the last recorded value and every gate hangs
    U.spawn(wave_loop)

    U.spawn(function()
        U.notify("ANON GTD", "Playing " .. tostring(macro.name) .. " · scale x" .. tostring(string.format("%.2f", scale))
            .. (#mismatches > 0 and (" · " .. #mismatches .. " mismatch(es)") or ""))

        align_to_start_wave(macro, opts)

        local loops = opts.loops or 1
        local run = 0
        local last = "done"
        while run < loops do
            if S.stop_requested then break end
            run = run + 1
            last = play_once(macro, scale, opts)
            if last == "stopped" then break end
            if UI_API and UI_API.status then UI_API.status() end
        end

        S.playing = false
        U.notify("ANON GTD", "Playback " .. tostring(last) .. " · runs " .. tostring(run)
            .. " · verified " .. tostring(S.stat.verified or 0) .. " · failed " .. tostring(S.stat.failed or 0)
            .. ((S.stat.skipped or 0) > 0 and (" · skipped " .. tostring(S.stat.skipped)) or ""))
        if UI_API and UI_API.status then UI_API.status() end
    end)
    return true, scale, mismatches
end

function PLAY.stop()
    S.stop_requested = true
end

-- manual anchor: "this wave just started now". Escape hatch when the counter
-- cannot be read (renamed gui, patch day) and for the SETUP tab self test.
function PLAY.mark_wave(wave)
    S.wave = wave
    S.wave_t0 = U.now()
    S.wave_prev = { cd = nil, cur = wave }
    if UI_API and UI_API.status then UI_API.status() end
    return S.wave_t0
end

function PLAY.status()
    return S
end

function PLAY.calibrate_sample(input_x, input_y, expected_x, expected_y)
    CONFIG.tap_offset_x = math.floor(input_x - expected_x + 0.5)
    CONFIG.tap_offset_y = math.floor(input_y - expected_y + 0.5)
    STORE.save_profile()
    return CONFIG.tap_offset_x, CONFIG.tap_offset_y
end
--==============================================================================
-- [4] UI — touch first, built from Instances (no Drawing dependency)
--==============================================================================

local UI = {}

local C = {
    bg      = Color3.fromRGB(14, 15, 18),
    panel   = Color3.fromRGB(20, 22, 27),
    panel2  = Color3.fromRGB(27, 30, 36),
    line    = Color3.fromRGB(44, 48, 56),
    text    = Color3.fromRGB(232, 234, 238),
    dim     = Color3.fromRGB(138, 145, 158),
    accent  = Color3.fromRGB(90, 200, 160),
    danger  = Color3.fromRGB(226, 88, 88),
    warn    = Color3.fromRGB(228, 176, 74),
}

local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    if parent then inst.Parent = parent end
    return inst
end

local function apply_round(inst, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = inst
    return c
end

local function apply_pad(inst, p)
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, p)
    pad.PaddingRight = UDim.new(0, p)
    pad.PaddingTop = UDim.new(0, p)
    pad.PaddingBottom = UDim.new(0, p)
    pad.Parent = inst
    return pad
end

local function mk_label(parent, text, size, color, y)
    return new("TextLabel", {
        BackgroundTransparency = 1,
        Text = text or "",
        TextColor3 = U.fix_contrast(color or C.text, C.bg),
        TextSize = size or 13,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        Size = UDim2.new(1, 0, 0, 18),
        Position = UDim2.new(0, 0, 0, y or 0),
        RichText = false,
    }, parent)
end

local function mk_button(parent, text, size, pos, color, cb, bg_color)
    local bg = bg_color or C.panel2
    local b = new("TextButton", {
        Text = text,
        TextColor3 = U.fix_contrast(color or C.text, bg),
        TextSize = 13,
        Font = Enum.Font.GothamMedium,
        BackgroundColor3 = bg,
        AutoButtonColor = true,
        Size = size,
        Position = pos,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, parent)
    apply_round(b, 6)
    UI.buttons = UI.buttons or {}
    table.insert(UI.buttons, { obj = b, text = text })
    if cb then
        b.MouseButton1Click:Connect(function()
            local ok, err = pcall(cb)
            if not ok then U.notify("ANON GTD", "error: " .. tostring(err)) end
        end)
    end
    return b
end

local function mk_box(parent, placeholder, size, pos)
    local t = new("TextBox", {
        Text = "",
        PlaceholderText = placeholder or "",
        PlaceholderColor3 = C.dim,
        TextColor3 = C.text,
        TextSize = 13,
        Font = Enum.Font.Gotham,
        BackgroundColor3 = C.panel2,
        ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = size,
        Position = pos,
    }, parent)
    apply_round(t, 6)
    apply_pad(t, 6)
    return t
end

local function mk_scroll(parent, pos, height)
    local f = new("ScrollingFrame", {
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height),
        Position = pos,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = C.line,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, parent)
    local lay = Instance.new("UIListLayout")
    lay.Padding = UDim.new(0, 4)
    lay.SortOrder = Enum.SortOrder.LayoutOrder
    lay.Parent = f
    return f, lay
end

--------------------------------------------------------------------------------
-- window shell
--------------------------------------------------------------------------------

local function gui_parent()
    local ok, hui = pcall(function()
        if type(gethui) == "function" then return gethui() end
        return nil
    end)
    if ok and hui then return hui end
    if LP then
        local pg = LP:FindFirstChild("PlayerGui")
        if pg then return pg end
    end
    local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
    if ok2 and cg then return cg end
    return LP:FindFirstChild("PlayerGui")
end

local ROOT = new("ScreenGui", {
    Name = "ANON_GTD",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 9999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, gui_parent())

MANUAL_HIDE = false

local MAIN = new("Frame", {
    Name = "Main",
    Size = UDim2.new(0, 400, 0, 366),
    Position = UDim2.new(0, 24, 0, 90),
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Active = false,
}, ROOT)
apply_round(MAIN, 10)

local HEAD = new("Frame", {
    Size = UDim2.new(1, 0, 0, 32),
    BackgroundColor3 = C.panel,
    BorderSizePixel = 0,
}, MAIN)
apply_round(HEAD, 10)
mk_label(HEAD, "ANON · GTD macro", 13, C.accent, 7).Position = UDim2.new(0, 12, 0, 0)
local HEAD_VER = mk_label(HEAD, "v" .. CONFIG.version, 11, C.dim, 9)
HEAD_VER.Position = UDim2.new(1, -104, 0, 0)
HEAD_VER.Size = UDim2.new(0, 40, 0, 14)
HEAD_VER.TextXAlignment = Enum.TextXAlignment.Right

-- collapsed state: a small bar that never disappears with the panel, so the panel
-- can always be brought back on a phone (the minimize button lives inside the panel)
local MINI = new("TextButton", {
    Name = "MiniBar",
    Size = UDim2.new(0, 140, 0, 26),
    Position = UDim2.new(0, 24, 0, 90),
    BackgroundColor3 = C.panel,
    TextColor3 = U.fix_contrast(C.accent, C.panel),
    TextSize = 12,
    Font = Enum.Font.GothamMedium,
    Text = "ANON · GTD  ▲",
    Visible = false,
    ZIndex = 15,
}, ROOT)
apply_round(MINI, 13)
MINI.MouseButton1Click:Connect(function()
    MANUAL_HIDE = false
    MINI.Visible = false
    MAIN.Visible = true
    UI.status()
end)

local function collapse_panel()
    MANUAL_HIDE = true
    MAIN.Visible = false
    MINI.Visible = not S.playing
    MINI.Text = S.recording and ("ANON ● REC " .. tostring(REC.step_count()) .. "  ▲") or "ANON · GTD  ▲"
end

local MIN_BTN = mk_button(HEAD, "—", UDim2.new(0, 26, 0, 22), UDim2.new(1, -60, 0, 5), C.dim, collapse_panel)
local CLOSE_BTN = mk_button(HEAD, "x", UDim2.new(0, 22, 0, 22), UDim2.new(1, -30, 0, 5), C.danger, collapse_panel)

-- drag
do
    local dragging, drag_start, start_pos = false, nil, nil
    HEAD.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            drag_start = UIS:GetMouseLocation()
            start_pos = MAIN.Position
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local d = UIS:GetMouseLocation() - drag_start
            MAIN.Position = UDim2.new(0, start_pos.X.Offset + d.X, 0, start_pos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

local TABBAR = new("Frame", {
    Size = UDim2.new(1, -16, 0, 28),
    Position = UDim2.new(0, 8, 0, 38),
    BackgroundTransparency = 1,
}, MAIN)
local tab_lay = Instance.new("UIListLayout")
tab_lay.FillDirection = Enum.FillDirection.Horizontal
tab_lay.Padding = UDim.new(0, 6)
tab_lay.Parent = TABBAR

local PAGES = {}
local TAB_BUTTONS = {}
local function show_page(name)
    for k, p in pairs(PAGES) do
        p.Visible = (k == name)
    end
    for k, b in pairs(TAB_BUTTONS) do
        b.BackgroundColor3 = (k == name) and C.accent or C.panel2
        b.TextColor3 = (k == name) and C.bg or C.text
    end
end

local function mk_tab(name, label)
    local b = mk_button(TABBAR, label, UDim2.new(0, 92, 0, 26), UDim2.new(0, 0, 0, 0), C.text, function()
        show_page(name)
    end)
    TAB_BUTTONS[name] = b
    local page = new("Frame", {
        Size = UDim2.new(1, -16, 1, -80),
        Position = UDim2.new(0, 8, 0, 72),
        BackgroundTransparency = 1,
        Visible = false,
    }, MAIN)
    PAGES[name] = page
    return page
end

--------------------------------------------------------------------------------
-- status line
--------------------------------------------------------------------------------

local REC_PAGE   = mk_tab("rec", "RECORD")
local MAC_PAGE   = mk_tab("macros", "MACROS")
local SET_PAGE   = mk_tab("setup", "SETUP")
local CFG_PAGE   = mk_tab("cfg", "CONFIG")

local status_label = mk_label(MAIN, "idle", 12, C.dim, 0)
status_label.Size = UDim2.new(1, -16, 0, 16)
status_label.Position = UDim2.new(0, 8, 1, -20)

--------------------------------------------------------------------------------
-- toast
--------------------------------------------------------------------------------

local TOAST = new("TextLabel", {
    Size = UDim2.new(0, 260, 0, 26),
    Position = UDim2.new(0, 24, 0, 60),
    BackgroundColor3 = C.panel2,
    TextColor3 = C.text,
    TextSize = 12,
    Font = Enum.Font.Gotham,
    Visible = false,
    Text = "",
}, ROOT)
apply_round(TOAST, 6)
local toast_token = 0
function UI.toast(text)
    toast_token = toast_token + 1
    local my = toast_token
    TOAST.Text = "  " .. tostring(text)
    TOAST.Visible = true
    task.delay(2.2, function()
        if my == toast_token then TOAST.Visible = false end
    end)
end

--------------------------------------------------------------------------------
-- floating stop pill (always available, never part of the recording)
--------------------------------------------------------------------------------

local PILL = new("TextButton", {
    Name = "StopPill",
    Size = UDim2.new(0, 84, 0, 30),
    Position = UDim2.new(0, 12, 0, 40),
    BackgroundColor3 = C.danger,
    TextColor3 = Color3.new(1, 1, 1),
    TextSize = 13,
    Font = Enum.Font.GothamBold,
    Text = "■ STOP",
    Visible = false,
    ZIndex = 20,
}, ROOT)
apply_round(PILL, 15)
PILL.MouseButton1Click:Connect(function()
    if S.recording then
        REC.finalize(nil, false)
        U.notify("ANON GTD", "Recording stopped and saved")
    end
    if S.playing then
        PLAY.stop()
        U.notify("ANON GTD", "Stopping playback...")
    end
    UI.status()
end)

--------------------------------------------------------------------------------
-- RECORD page
--------------------------------------------------------------------------------

local rec_status = mk_label(REC_PAGE, "no active recording", 13, C.text, 0)
local rec_ctx = mk_label(REC_PAGE, "", 11, C.dim, 20)
rec_ctx.Size = UDim2.new(1, 0, 0, 32)
rec_ctx.TextYAlignment = Enum.TextYAlignment.Top
rec_ctx.TextWrapped = true

local rec_hint = mk_label(REC_PAGE, "", 11, C.warn, 56)
rec_hint.Size = UDim2.new(1, 0, 0, 14)

local NAME_BOX = mk_box(REC_PAGE, "macro name (optional)", UDim2.new(1, 0, 0, 30), UDim2.new(0, 0, 0, 122))

local PIN_TOGGLE = { pinned = false }

local REC_BTN = mk_button(REC_PAGE, "● START RECORDING", UDim2.new(0, 190, 0, 40), UDim2.new(0, 0, 0, 74), C.bg, function()
    if S.recording then
        local m, err = REC.finalize(NAME_BOX.Text ~= "" and NAME_BOX.Text or nil, PIN_TOGGLE.pinned)
        if not m then
            U.notify("ANON GTD", "Save failed: " .. tostring(err))
        end
        NAME_BOX.Text = ""
    else
        local ok, err = REC.start()
        if not ok then U.notify("ANON GTD", tostring(err)) end
    end
    UI.refresh_macros()
    UI.status()
end, C.accent)
REC_BTN.TextColor3 = U.fix_contrast(C.bg, C.accent)

local DISCARD_BTN = mk_button(REC_PAGE, "DISCARD", UDim2.new(0, 90, 0, 40), UDim2.new(0, 200, 0, 74), C.danger, function()
    REC.discard()
    U.notify("ANON GTD", "Recording discarded")
    UI.status()
end)

local PIN_REC_BTN
PIN_REC_BTN = mk_button(REC_PAGE, "pin on save: OFF", UDim2.new(0, 150, 0, 26), UDim2.new(0, 0, 0, 158), C.dim, function()
    PIN_TOGGLE.pinned = not PIN_TOGGLE.pinned
    PIN_REC_BTN.Text = "pin on save: " .. (PIN_TOGGLE.pinned and "ON" or "OFF")
    PIN_REC_BTN.TextColor3 = U.fix_contrast(PIN_TOGGLE.pinned and C.accent or C.dim, C.panel2)
end)

-- what happened on the last save / why a save failed, in plain words
local REC_LAST = mk_label(REC_PAGE, "", 10, C.warn, 0)
REC_LAST.Size = UDim2.new(1, 0, 0, 44)
REC_LAST.Position = UDim2.new(0, 0, 0, 190)
REC_LAST.TextYAlignment = Enum.TextYAlignment.Top
REC_LAST.TextWrapped = true

local LIVE_FRAME, _ = mk_scroll(REC_PAGE, UDim2.new(0, 0, 0, 236), 74)
local live_rows = {}
local function live_add(step, index)
    if #live_rows > 11 then
        local old = table.remove(live_rows, 1)
        if old then old:Destroy() end
    end
    local tower = step.tower and (" · " .. step.tower) or ""
    local desc = string.format("%3d  %-4s  w%s  dt%s%s", index, step.kind,
        tostring(step.wave or "-"), step.dt and string.format("%.2f", step.dt) or "-", tower)
    local row = mk_label(LIVE_FRAME, desc, 11, step.tower and C.accent or C.dim, 0)
    row.Size = UDim2.new(1, 0, 0, 14)
    row.LayoutOrder = index
    table.insert(live_rows, row)
end

--------------------------------------------------------------------------------
-- MACROS page
--------------------------------------------------------------------------------

local FILTER_BOX = mk_box(MAC_PAGE, "filter name / mode / map", UDim2.new(0, 220, 0, 28), UDim2.new(0, 0, 0, 0))
local PIN_FILTER = { on = false }
local PIN_FILTER_BTN = mk_button(MAC_PAGE, "pinned only: OFF", UDim2.new(0, 120, 0, 28), UDim2.new(0, 226, 0, 0), C.dim, function()
    PIN_FILTER.on = not PIN_FILTER.on
    PIN_FILTER_BTN.Text = "pinned only: " .. (PIN_FILTER.on and "ON" or "OFF")
    PIN_FILTER_BTN.TextColor3 = U.fix_contrast(PIN_FILTER.on and C.accent or C.dim, C.panel2)
    UI.refresh_macros()
end)
local REFRESH_BTN = mk_button(MAC_PAGE, "refresh", UDim2.new(0, 62, 0, 28), UDim2.new(1, -62, 0, 0), C.dim, function()
    UI.refresh_macros()
end)

local LOOP_SETTINGS = { loops = 1 }
local LOOP_BTN = mk_button(MAC_PAGE, "loops: 1", UDim2.new(0, 90, 0, 26), UDim2.new(0, 0, 0, 34), C.dim, function()
    local seq = { 1, 5, 25, math.huge }
    local cur = 1
    for i, v in ipairs(seq) do if v == LOOP_SETTINGS.loops then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    LOOP_SETTINGS.loops = seq[cur]
    LOOP_BTN.Text = "loops: " .. (LOOP_SETTINGS.loops == math.huge and "inf" or tostring(LOOP_SETTINGS.loops))
end)

local macro_list, macro_list_lay = mk_scroll(MAC_PAGE, UDim2.new(0, 0, 0, 68), 214)

local CONFIRM = new("Frame", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.1,
    Visible = false,
    ZIndex = 30,
}, ROOT)
apply_round(CONFIRM, 10)
local CONFIRM_TITLE = mk_label(CONFIRM, "play anyway?", 14, C.warn, 14)
CONFIRM_TITLE.Position = UDim2.new(0, 14, 0, 14)
local CONFIRM_BODY = mk_label(CONFIRM, "", 12, C.text, 40)
CONFIRM_BODY.Size = UDim2.new(1, -28, 0, 150)
CONFIRM_BODY.Position = UDim2.new(0, 14, 0, 40)
CONFIRM_BODY.TextYAlignment = Enum.TextYAlignment.Top
CONFIRM_BODY.TextWrapped = true
local confirm_yes, confirm_no

local function ask_confirm(text, on_yes)
    CONFIRM_BODY.Text = text
    CONFIRM.Visible = true
    if confirm_yes then confirm_yes:Destroy() end
    if confirm_no then confirm_no:Destroy() end
    confirm_yes = mk_button(CONFIRM, "PLAY ANYWAY", UDim2.new(0, 150, 0, 34), UDim2.new(0, 14, 1, -50), C.warn, function()
        CONFIRM.Visible = false
        if on_yes then on_yes() end
    end)
    confirm_no = mk_button(CONFIRM, "CANCEL", UDim2.new(0, 110, 0, 34), UDim2.new(0, 174, 1, -50), C.dim, function()
        CONFIRM.Visible = false
    end)
end

local function play_macro(id, force)
    local macro = STORE.load_macro(id)
    if not macro then
        U.notify("ANON GTD", "macro file missing")
        return
    end
    if not force then
        local mismatches = PLAY.compat(macro)
        if #mismatches > 0 then
            ask_confirm("context differs from recording:\n\n- " .. table.concat(mismatches, "\n- ")
                .. "\n\nplayback anchors on wave numbers, so a different map or mode will place units in the wrong places.",
                function() PLAY.run(macro, { loops = LOOP_SETTINGS.loops, force = true }) end)
            return
        end
    end
    local ok, err = PLAY.run(macro, { loops = LOOP_SETTINGS.loops, force = force })
    if not ok then U.notify("ANON GTD", tostring(err)) end
    UI.status()
end

local function export_macro(id)
    local macro = STORE.load_macro(id)
    if not macro then return end
    local raw = U.json_encode(macro)
    local code = U.base64_encode(raw)
    if type(setclipboard) == "function" then
        pcall(setclipboard, code)
        U.notify("ANON GTD", "export copied to clipboard (" .. #code .. " chars)")
    else
        U.notify("ANON GTD", "no setclipboard on this executor; use SETUP > dump")
    end
end

local function rename_macro(id)
    local macro = STORE.load_macro(id)
    if not macro then return end
    local entry = STORE.entry_of(id)
    local old = (entry and entry.name) or macro.name or ""

    local panel = new("Frame", {
        Size = UDim2.new(0, 320, 0, 110),
        Position = UDim2.new(0.5, -160, 0.5, -55),
        BackgroundColor3 = C.bg,
        BorderSizePixel = 0,
        ZIndex = 35,
    }, ROOT)
    apply_round(panel, 10)
    mk_label(panel, "rename macro", 13, C.accent, 10).Position = UDim2.new(0, 12, 0, 10)
    local box = mk_box(panel, "new name", UDim2.new(1, -24, 0, 30), UDim2.new(0, 12, 0, 34))
    box.Text = old
    box.ZIndex = 36
    local btn = mk_button(panel, "SAVE", UDim2.new(0, 100, 0, 28), UDim2.new(1, -112, 0, 72), C.accent, function()
        if box.Text ~= "" then
            STORE.rename(id, box.Text)
            UI.refresh_macros()
            U.notify("ANON GTD", "renamed to " .. box.Text)
        end
        panel:Destroy()
    end)
    box.FocusLost:Connect(function()
        if box.Text ~= "" then
            STORE.rename(id, box.Text)
            UI.refresh_macros()
        end
        panel:Destroy()
    end)
end

function UI.refresh_macros()
    for _, c in ipairs(macro_list:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end

    local filter = string.lower(FILTER_BOX.Text or "")
    local entries = STORE.sorted_entries()
    local shown = 0

    for i, e in ipairs(entries) do
        local hay = string.lower(table.concat({
            tostring(e.name or ""), tostring(e.mode or ""), tostring(e.difficulty or ""),
            tostring(e.map or ""), tostring(e.speed or ""),
        }, " "))
        local ok = true
        if filter ~= "" and not string.find(hay, filter, 1, true) then ok = false end
        if PIN_FILTER.on and not e.pinned then ok = false end

        if ok then
            shown = shown + 1
            local row = new("Frame", {
                Size = UDim2.new(1, 0, 0, 46),
                BackgroundColor3 = C.panel,
                BorderSizePixel = 0,
                LayoutOrder = i,
            }, macro_list)
            apply_round(row, 6)

            local title = mk_label(row, (e.pinned and "★ " or "") .. tostring(e.name or "?")
                .. (e.memory_only and "  [MEMORY ONLY]" or (e.recovered and "  [recovered]" or "")), 13,
                e.pinned and C.accent or C.text, 2)
            title.Position = UDim2.new(0, 8, 0, 4)
            title.Size = UDim2.new(1, -150, 0, 16)

            local ctx_line = string.format("%s · %s · %s · x%s · %s waves · %s steps · %s",
                tostring(e.difficulty or "?"), tostring(e.mode or "?"), tostring(e.map or "?"),
                tostring(e.speed or "?"), tostring(e.wave_total or "?"), tostring(e.steps or "?"),
                U.fmt_date(e.created))
            local sub = mk_label(row, ctx_line, 10, C.dim, 22)
            sub.Position = UDim2.new(0, 8, 0, 22)
            sub.Size = UDim2.new(1, -150, 0, 20)
            sub.TextWrapped = false
            sub.TextTruncate = Enum.TextTruncate.AtEnd

            local function row_btn(text, x, w, color, cb)
                return mk_button(row, text, UDim2.new(0, w, 0, 22), UDim2.new(1, x, 0, 12), color, cb)
            end

            row_btn("GO",  -178, 30, C.accent, function() play_macro(e.id, false) end)
            row_btn("PIN", -144, 30, e.pinned and C.accent or C.dim, function()
                STORE.pin(e.id, not e.pinned)
                UI.refresh_macros()
            end)
            row_btn("NM",  -110, 28, C.text, function() rename_macro(e.id) end)
            row_btn("EXP", -78, 30, C.text, function() export_macro(e.id) end)
            row_btn("DEL", -44, 30, C.danger, function()
                ask_confirm("delete macro \"" .. tostring(e.name) .. "\"?", function()
                    STORE.delete_macro(e.id)
                    UI.refresh_macros()
                end)
            end)
        end
    end

    if shown == 0 then
        local diag = STORE.diagnose()
        local head = "no macros yet — record one on the RECORD tab"
        if STORE.index and #STORE.index.entries > 0 then
            head = "nothing matches the filter"
        end
        local l = mk_label(macro_list, head .. "\n" .. diag, 10, C.dim, 6)
        l.Size = UDim2.new(1, 0, 0, 76)
        l.TextYAlignment = Enum.TextYAlignment.Top
        l.TextWrapped = true
    end
end

--------------------------------------------------------------------------------
-- SETUP page (discovery + calibration)
--------------------------------------------------------------------------------

local setup_out, _ = mk_scroll(SET_PAGE, UDim2.new(0, 0, 0, 72), 206)
local function setup_clear()
    for _, c in ipairs(setup_out:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
end
local setup_line_i = 0
local function setup_line(text, color)
    setup_line_i = setup_line_i + 1
    local l = mk_label(setup_out, text, 11, color or C.dim, 0)
    l.Size = UDim2.new(1, 0, 0, 15)
    l.LayoutOrder = setup_line_i
    return l
end

local last_report = ""

local function run_discovery()
    setup_clear()
    setup_line_i = 0
    local ctx, extra = PROBE.detect_context()
    S.last_ctx = ctx

    setup_line("== CONTEXT (stamped into every macro) ==", C.accent)
    setup_line("place_id   " .. tostring(ctx.place_id))
    setup_line("job_id     " .. tostring(ctx.job_id))
    setup_line("mode       " .. tostring(ctx.mode) .. "   [" .. tostring(ctx.sources.mode) .. "]")
    setup_line("difficulty " .. tostring(ctx.difficulty) .. "   [" .. tostring(ctx.sources.difficulty) .. "]")
    setup_line("map        " .. tostring(ctx.map_label) .. "   [" .. tostring(ctx.sources.map) .. "]")
    setup_line("map_sig    " .. tostring(ctx.map_sig))
    setup_line("speed      x" .. tostring(ctx.speed))
    setup_line("waves      " .. tostring(ctx.wave_cur) .. " / " .. tostring(ctx.wave_total))
    setup_line("countdown  " .. tostring(ctx.countdown))
    setup_line("seeds      " .. tostring(ctx.seeds))
    setup_line("labels     " .. tostring(ctx.label_count))

    local units, usize = PROBE.loadout()
    setup_line("")
    setup_line("== LOADOUT ==", C.accent)
    if #units == 0 then
        setup_line("none detected (set override or equip units before recording)")
    else
        setup_line(table.concat(units, ", ") .. "   [" .. tostring(usize) .. "]")
    end

    setup_line("")
    setup_line("== ANCHORS ==", C.accent)
    setup_line("wave label " .. tostring(STORE.profile.wave_path or ctx.sources.wave or "not pinned"))
    setup_line("container  " .. tostring(STORE.profile.container_path or "auto"))
    setup_line("tap offset " .. tostring(CONFIG.tap_offset_x) .. "," .. tostring(CONFIG.tap_offset_y))
    setup_line("remote spy " .. (PROBE.spy_supported and "available" or "NOT available on this executor"))
    setup_line("touch sim  " .. (CAP.touch and "available" or "unavailable (mouse fallback)"))
    setup_line("gui fire   " .. (CAP.firesignal and "firesignal" or (CAP.getconn and "getconnections" or "none")))

    setup_line("")
    setup_line("== REMOTE CANDIDATES (tap to pin the wave one) ==", C.accent)
    local remotes = PROBE.scan_remotes()
    S.last_remotes = remotes
    for i = 1, math.min(#remotes, 8) do
        local r = remotes[i]
        local l = setup_line(string.format("%d. %s  (%s, score %d)", i, r.name, r.class, r.score),
            r.score >= 4 and C.accent or C.dim)
        l.TextXAlignment = Enum.TextXAlignment.Left
    end
    if #remotes == 0 then setup_line("no remote found (everything may be Attribute-driven)") end

    setup_line("")
    setup_line("== WORKSPACE FINGERPRINT (first 8) ==", C.accent)
    for i = 1, math.min(#extra.sig_parts, 8) do
        setup_line("  " .. extra.sig_parts[i])
    end

    setup_line("")
    setup_line("== STORE ==", C.accent)
    local diag = STORE.diagnose()
    for line in string.gmatch(diag, "[^\n]+") do setup_line(line) end
    if (STORE.recovered or 0) > 0 then
        setup_line("recovered from disk: " .. tostring(STORE.recovered), C.accent)
    end

    local lines = {}
    for _, c in ipairs(setup_out:GetChildren()) do
        if c:IsA("TextLabel") then lines[#lines + 1] = c.Text end
    end
    last_report = table.concat(lines, "\n")
    PROBE.report.text = last_report
    PROBE.report.ctx = ctx
    PROBE.report.at = os.time()
    U.notify("ANON GTD", "discovery done")
end

-- calibration: tap a known crosshair, measure the offset between input space and gui space
local CALIB = { active = false, frame = nil }

local function calibrate()
    if CALIB.frame then CALIB.frame:Destroy() end
    local f = new("TextButton", {
        Size = UDim2.new(0, 64, 0, 64),
        Position = UDim2.new(0, 80, 0, 200),
        BackgroundColor3 = C.warn,
        Text = "+",
        TextColor3 = C.bg,
        TextSize = 28,
        Font = Enum.Font.GothamBold,
        ZIndex = 40,
    }, ROOT)
    apply_round(f, 32)
    CALIB.frame = f
    CALIB.active = true
    U.notify("ANON GTD", "tap the yellow + once")

    local conn
    conn = UIS.InputBegan:Connect(function(input)
        if not CALIB.active then return end
        if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
        local ok, ap, as = pcall(function() return f.AbsolutePosition, f.AbsoluteSize end)
        if not ok then return end
        local expect_x = ap.X + as.X / 2
        local expect_y = ap.Y + as.Y / 2
        local ox, oy = PLAY.calibrate_sample(input.Position.X, input.Position.Y, expect_x, expect_y)
        CALIB.active = false
        if conn then conn:Disconnect() end
        f:Destroy()
        CALIB.frame = nil
        U.notify("ANON GTD", string.format("tap offset: %d,%d", ox, oy))
        run_discovery()
    end)
end

local DISC_BTN = mk_button(SET_PAGE, "RUN DISCOVERY", UDim2.new(0, 118, 0, 28), UDim2.new(0, 0, 0, 0), C.bg, run_discovery, C.accent)
mk_button(SET_PAGE, "COPY REPORT", UDim2.new(0, 106, 0, 28), UDim2.new(0, 124, 0, 0), C.text, function()
    if type(setclipboard) == "function" then
        pcall(setclipboard, last_report)
        U.notify("ANON GTD", "report copied (" .. tostring(#last_report) .. " chars)")
    else
        print("===== ANON GTD DISCOVERY REPORT =====")
        print(last_report)
        print("===== END =====")
        U.notify("ANON GTD", "no setclipboard — report printed to the executor console")
    end
end)
mk_button(SET_PAGE, "PIN ANCHOR", UDim2.new(0, 100, 0, 28), UDim2.new(0, 236, 0, 0), C.text, function()
    local ctx = PROBE.detect_context()
    if ctx.sources.wave then
        STORE.profile.wave_path = ctx.sources.wave
        STORE.save_profile()
        U.notify("ANON GTD", "pinned: " .. tostring(ctx.sources.wave))
    else
        U.notify("ANON GTD", "no wave label detected — set overrides first")
    end
end)
mk_button(SET_PAGE, "MARK WAVE NOW", UDim2.new(0, 130, 0, 28), UDim2.new(0, 0, 0, 34), C.warn, function()
    local ctx = PROBE.detect_context()
    local w = ctx.wave_cur or S.wave or 1
    PLAY.mark_wave(w)
    U.notify("ANON GTD", "wave " .. tostring(w) .. " anchored as T0")
end)
mk_button(SET_PAGE, "CALIBRATE TAP", UDim2.new(0, 120, 0, 28), UDim2.new(0, 136, 0, 34), C.warn, calibrate)
mk_button(SET_PAGE, "RESCAN DISK", UDim2.new(0, 110, 0, 28), UDim2.new(0, 262, 0, 34), C.danger, function()
    local added = STORE.rebuild_index()
    UI.refresh_macros()
    run_discovery()
    U.notify("ANON GTD", "index rescan: " .. tostring(added) .. " recovered, "
        .. tostring(#STORE.index.entries) .. " total", 6)
end)

-- manual overrides: type "mode=Impossible" style lines into this box and apply
local OVR_BOX = mk_box(SET_PAGE, "override e.g. mode=Impossible  speed=3  map=Dojo   (comma separated)",
    UDim2.new(1, -8, 0, 26), UDim2.new(0, 0, 1, -30))
mk_button(SET_PAGE, "apply", UDim2.new(0, 60, 0, 26), UDim2.new(1, -66, 1, -30), C.accent, function()
    local ov = {}
    for pair in string.gmatch(OVR_BOX.Text or "", "[^,]+") do
        local k, v = string.match(pair, "^%s*(%w+)%s*=%s*(.-)%s*$")
        if k and v and v ~= "" then
            if k == "speed" or k == "wave_total" then v = tonumber(v) or v end
            ov[k] = v
        end
    end
    STORE.profile.overrides = ov
    STORE.save_profile()
    U.notify("ANON GTD", "overrides applied to context detection")
    run_discovery()
end)

--------------------------------------------------------------------------------
-- CONFIG page
--------------------------------------------------------------------------------

local cfg_scroll, _ = mk_scroll(CFG_PAGE, UDim2.new(0, 0, 0, 0), 268)
local cfg_i = 0
local function cfg_row(text, btn_text, cb)
    cfg_i = cfg_i + 1
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 30),
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        LayoutOrder = cfg_i,
    }, cfg_scroll)
    apply_round(row, 6)
    mk_label(row, text, 12, C.text, 7).Size = UDim2.new(1, -130, 0, 16)
    local b = mk_button(row, btn_text, UDim2.new(0, 118, 0, 24), UDim2.new(1, -124, 0, 3), C.bg, cb, C.accent)
    return b
end

cfg_row("position jitter (px)", tostring(CONFIG.jitter_pos), function()
    local seq = { 0, 1, 2, 4 }
    local cur = 1
    for i, v in ipairs(seq) do if v == CONFIG.jitter_pos then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    CONFIG.jitter_pos = seq[cur]
    U.notify("ANON GTD", "position jitter " .. tostring(CONFIG.jitter_pos) .. "px")
end)

local time_btn
time_btn = cfg_row("time jitter", string.format("%dms", math.floor(CONFIG.jitter_time * 1000)), function()
    local seq = { 0, 0.010, 0.025, 0.050 }
    local cur = 1
    for i, v in ipairs(seq) do if math.abs(v - CONFIG.jitter_time) < 0.001 then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    CONFIG.jitter_time = seq[cur]
    time_btn.Text = string.format("%dms", math.floor(CONFIG.jitter_time * 1000))
end)

local speed_btn
speed_btn = cfg_row("speed mismatch", CONFIG.speed_mode, function()
    CONFIG.speed_mode = (CONFIG.speed_mode == "scale") and "block" or "scale"
    local blk = CONFIG.speed_mode == "block"
    speed_btn.Text = CONFIG.speed_mode
    speed_btn.BackgroundColor3 = blk and C.warn or C.accent
    speed_btn.TextColor3 = U.fix_contrast(C.bg, speed_btn.BackgroundColor3)
end)

local click_btn
click_btn = cfg_row("click method", CONFIG.click_mode, function()
    local seq = { "auto", "ui", "touch", "mouse" }
    local cur = 1
    for i, v in ipairs(seq) do if v == CONFIG.click_mode then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    CONFIG.click_mode = seq[cur]
    click_btn.Text = CONFIG.click_mode
end)

local follow_btn
follow_btn = cfg_row("follow ui/world at play", CONFIG.follow_ui and "ON" or "OFF", function()
    CONFIG.follow_ui = not CONFIG.follow_ui
    follow_btn.Text = CONFIG.follow_ui and "ON" or "OFF"
end)

local followw_btn
followw_btn = cfg_row("follow world point", CONFIG.follow_world and "ON" or "OFF", function()
    CONFIG.follow_world = not CONFIG.follow_world
    followw_btn.Text = CONFIG.follow_world and "ON" or "OFF"
end)

local retry_btn
retry_btn = cfg_row("placement retries", tostring(CONFIG.retries), function()
    CONFIG.retries = (CONFIG.retries + 1) % 4
    retry_btn.Text = tostring(CONFIG.retries)
end)

local verify_btn
verify_btn = cfg_row("verify timeout", string.format("%.1fs", CONFIG.verify_timeout), function()
    local seq = { 0.8, 1.5, 2.5, 4.0 }
    local cur = 1
    for i, v in ipairs(seq) do if math.abs(v - CONFIG.verify_timeout) < 0.01 then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    CONFIG.verify_timeout = seq[cur]
    verify_btn.Text = string.format("%.1fs", CONFIG.verify_timeout)
end)

local wtimeout_btn
wtimeout_btn = cfg_row("wave wait timeout", string.format("%ds", CONFIG.wave_timeout), function()
    local seq = { 20, 45, 90, 180 }
    local cur = 1
    for i, v in ipairs(seq) do if v == CONFIG.wave_timeout then cur = i end end
    cur = cur + 1
    if cur > #seq then cur = 1 end
    CONFIG.wave_timeout = seq[cur]
    wtimeout_btn.Text = string.format("%ds", CONFIG.wave_timeout)
end)

local afk_btn
afk_btn = cfg_row("anti-afk kick", CONFIG.anti_afk and "ON" or "OFF", function()
    CONFIG.anti_afk = not CONFIG.anti_afk
    afk_btn.Text = CONFIG.anti_afk and "ON" or "OFF"
end)

local notify_btn
notify_btn = cfg_row("notifications", CONFIG.notify and "ON" or "OFF", function()
    CONFIG.notify = not CONFIG.notify
    notify_btn.Text = CONFIG.notify and "ON" or "OFF"
end)

local autocollapse_btn
autocollapse_btn = cfg_row("auto-collapse on record", CONFIG.auto_collapse_on_record and "ON" or "OFF", function()
    CONFIG.auto_collapse_on_record = not CONFIG.auto_collapse_on_record
    autocollapse_btn.Text = CONFIG.auto_collapse_on_record and "ON" or "OFF"
end)

cfg_row("store backend", FS.available and "file API" or "memory", function()
    U.notify("ANON GTD", FS.available
        and ("macros live in " .. STORE.dir)
        or "this executor has no file API: macros live only for this session")
end)

cfg_row("import macro (base64)", "paste", function()
    local box = mk_box(CFG_PAGE, "paste base64 export here", UDim2.new(1, -8, 0, 28), UDim2.new(0, 0, 1, -32))
    box.FocusLost:Connect(function()
        local raw = U.base64_decode(box.Text or "")
        local macro = raw ~= "" and U.json_decode(raw) or nil
        if type(macro) == "table" and macro.steps then
            if not macro.id then macro.id = STORE.new_id() end
            STORE.save_macro(macro)
            UI.refresh_macros()
            U.notify("ANON GTD", "imported: " .. tostring(macro.name))
        else
            U.notify("ANON GTD", "bad import string")
        end
        box:Destroy()
    end)
end)

--------------------------------------------------------------------------------
-- status + shared api for the engine
--------------------------------------------------------------------------------

function UI.status()
    local txt
    REC_LAST.Text = REC.last_report or ""
    if S.recording then
        local ctx = S.ctx or {}
        rec_status.Text = string.format("REC ●  %s  steps %d  wave %s",
            U.fmt_ms(REC.elapsed()), REC.step_count(), tostring(S.wave or "-"))
        local unit_txt = "not detected"
        if ctx.loadout and #ctx.loadout > 0 then
            unit_txt = table.concat(ctx.loadout, ", ")
        end
        rec_ctx.Text = string.format("%s · %s · %s · x%s · waves %s/%s\nunits: %s",
            tostring(ctx.mode or "?"), tostring(ctx.difficulty or "?"), tostring(ctx.map_label or "?"),
            tostring(ctx.speed or "?"), tostring(S.wave or ctx.wave_cur or "?"), tostring(S.wave_total or "?"),
            unit_txt)
        rec_hint.Text = (S.wave_t0 == nil) and "waiting for a wave anchor — start recording before or during a wave" or ""
        REC_BTN.Text = "■ STOP & SAVE"
        REC_BTN.BackgroundColor3 = C.danger
        REC_BTN.TextColor3 = U.fix_contrast(C.bg, C.danger)
        PILL.Visible = true
        MINI.Text = "ANON ● REC " .. tostring(REC.step_count()) .. "  ▲"
        MINI.Visible = MANUAL_HIDE
        if not MANUAL_HIDE then MAIN.Visible = true end
        txt = "recording"
    elseif S.playing then
        local st = S.stat or {}
        txt = string.format("PLAY ▶  step %s/%s  wave %s  late %s  missed %s  ok %s  fail %s",
            tostring(st.step), tostring(st.total), tostring(st.last_wave or S.wave or "-"),
            tostring(st.late), tostring(st.missed), tostring(st.verified), tostring(st.failed))
        REC_BTN.Text = "● START RECORDING"
        REC_BTN.BackgroundColor3 = C.accent
        REC_BTN.TextColor3 = U.fix_contrast(C.bg, C.accent)
        PILL.Visible = true
        MINI.Visible = false
        -- keep the panel out of the way of the replayed taps
        MAIN.Visible = false
    else
        rec_status.Text = "idle"
        rec_ctx.Text = ""
        rec_hint.Text = ""
        REC_BTN.Text = "● START RECORDING"
        REC_BTN.BackgroundColor3 = C.accent
        REC_BTN.TextColor3 = U.fix_contrast(C.bg, C.accent)
        PILL.Visible = false
        MINI.Text = "ANON · GTD  ▲"
        MINI.Visible = MANUAL_HIDE
        MAIN.Visible = not MANUAL_HIDE
        txt = string.format("idle · %s · x%s · %s",
            tostring((S.last_ctx and S.last_ctx.mode) or "?"),
            tostring((S.last_ctx and S.last_ctx.speed) or "?"),
            tostring((S.last_ctx and S.last_ctx.map_label) or "no context scanned yet"))
    end
    status_label.Text = "  " .. txt
end

UI_API.contains_point = function(x, y)
    if ROOT.Enabled == false then return false end
    local checks = {}
    if MAIN.Visible then checks[#checks + 1] = MAIN end
    if MINI.Visible then checks[#checks + 1] = MINI end
    if PILL.Visible then checks[#checks + 1] = PILL end
    if TOAST.Visible then checks[#checks + 1] = TOAST end
    if CALIB.frame then checks[#checks + 1] = CALIB.frame end
    for _, top in ipairs(checks) do
        local ok, list = pcall(function() return top:GetDescendants() end)
        if ok and list then
            local function hit(inst)
                if not inst:IsA("GuiObject") or not inst.Visible then return false end
                local ok2, ap, as = pcall(function() return inst.AbsolutePosition, inst.AbsoluteSize end)
                if not ok2 or not ap or not as then return false end
                if as.X <= 0 or as.Y <= 0 then return false end
                return x >= ap.X and x <= ap.X + as.X and y >= ap.Y and y <= ap.Y + as.Y
            end
            if hit(top) then return true end
            for _, d in ipairs(list) do
                if hit(d) then return true end
            end
        end
    end
    return false
end

-- exposed handles (console control + tests)
UI.root        = ROOT
UI.main        = MAIN
UI.mini        = MINI
UI.pill        = PILL
UI.toast_label = TOAST
UI.pages       = PAGES
UI.tabs        = TAB_BUTTONS
UI.collapse    = collapse_panel
UI.contains_point = function(x, y) return UI_API.contains_point(x, y) end

-- Contrast self test: returns every text that is not legible on its own background.
-- console: print(#getgenv().ANON_GTD.ui.audit_contrast())
function UI.audit_contrast(min_ratio)
    min_ratio = min_ratio or 3.9
    local bad = {}
    local function effective_bg(inst)
        local node = inst
        while node do
            local ok, bg, bt = pcall(function() return node.BackgroundColor3, node.BackgroundTransparency end)
            if ok and bg and (bt or 0) < 0.5 then return bg end
            node = node.Parent
        end
        return C.bg
    end
    local ok, list = pcall(function() return ROOT:GetDescendants() end)
    if ok and list then
        for _, d in ipairs(list) do
            local cls = d.ClassName
            if cls == "TextLabel" or cls == "TextButton" or cls == "TextBox" then
                local okp, txt, fg, tt = pcall(function() return d.Text, d.TextColor3, d.TextTransparency end)
                if okp and txt and txt ~= "" and fg and (tt or 0) < 0.9 then
                    local bg = effective_bg(d)
                    local ratio = U.contrast(fg, bg)
                    if ratio < min_ratio then
                        bad[#bad + 1] = {
                            text = txt, ratio = ratio, path = d:GetFullName(),
                            visible = d.Visible and true or false,
                        }
                    end
                end
            end
        end
    end
    return bad
end

UI_API.status = UI.status
UI_API.toast = UI.toast
UI_API.collapse = function() return UI.collapse() end
UI_API.live_step = function(step, index)
    if step.kind ~= "move" then live_add(step, index) end
    if S.recording then
        MINI.Text = "ANON ● REC " .. tostring(index) .. "  ▲"
    end
end
UI_API.refresh_macros = UI.refresh_macros

--------------------------------------------------------------------------------
-- anti afk + boot
--------------------------------------------------------------------------------

if CONFIG.anti_afk then
    U.spawn(function()
        LP.Idled:Connect(function()
            pcall(function() VirtualUser:ClickButton2(Vector2.new()) end)
        end)
    end)
end

SET_PAGE.Visible = false
CFG_PAGE.Visible = false
MAC_PAGE.Visible = false
REC_PAGE.Visible = true

-- idle watcher: keeps the wave counter live in the status bar and makes sure a
-- playback never aligns on a stale value. slow on purpose (1 s).
U.spawn(function()
    while true do
        if not (S.recording or S.playing) then
            local st = PROBE.wave_state_cheap()
            if st.cur then S.wave = st.cur end
            if st.total then S.wave_total = st.total end
            if UI.status then UI.status() end
        end
        task.wait(1.0)
    end
end)
for k, b in pairs(TAB_BUTTONS) do
    b.BackgroundColor3 = (k == "rec") and C.accent or C.panel2
    b.TextColor3 = (k == "rec") and C.bg or C.text
end

STORE.init()
UI.refresh_macros()
UI.status()

-- first run: no calibrated offset yet, offer the calibration
if STORE.profile.tap_offset_x == 0 and STORE.profile.tap_offset_y == 0 and not STORE.profile.calibrated then
    U.notify("ANON GTD", "first run: SETUP > CALIBRATE TAP if clicks land off by a few px")
end

-- exported handle, so you can drive it from the executor console too
local API = {
    config   = CONFIG,
    state    = S,
    store    = STORE,
    probe    = PROBE,
    recorder = REC,
    player   = PLAY,
    ui       = UI,
    repair   = { resolve_path = resolve_path },
}
getgenv().ANON_GTD = API

local place_ok = CONFIG.place_whitelist[game.PlaceId] ~= nil
if not place_ok then
    U.notify("ANON GTD", "this place (" .. tostring(game.PlaceId) .. ") is not on the whitelist — features may not map", 8)
end

U.notify("ANON GTD", "v" .. CONFIG.version .. " loaded · "
    .. (FS.available and "file api ok" or "no file api (session only)")
    .. " · " .. (CAP.touch and "touch sim ok" or "mouse sim only"), 6)

return API
