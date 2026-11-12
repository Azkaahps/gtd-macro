--[[
    ANON GTD · offline harness
    Runs Main.lua against a mocked Roblox surface (services, Instance, Enum,
    file api, VirtualInputManager, virtual clock + scheduler) so the whole
    boot -> record -> save -> load -> play chain is exercised without Roblox.
    Usage: luajit tools/mock_harness.lua   (or lua / lua5.4)
--]]

local HERE = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "."
local MAIN_PATH = HERE .. "/../Main.lua"
local WITH_SPY = (arg and arg[1] == "spy") or false
if WITH_SPY then print("== harness variant: executor WITH hookmetamethod (remote spy path) ==") end

--==============================================================================
-- virtual clock + scheduler
--==============================================================================

local VIRT = 1000.0
local tasks = {}
local task_mod = {}
local TUNPACK = table.unpack or unpack

function task_mod.spawn(fn, ...)
    local co = coroutine.create(fn)
    local args = { ... }
    table.insert(tasks, { co = co, args = args, wake = VIRT, started = false })
    return co
end

function task_mod.defer(fn, ...) return task_mod.spawn(fn, ...) end

function task_mod.delay(t, fn, ...)
    local co = coroutine.create(fn)
    local args = { ... }
    table.insert(tasks, { co = co, args = args, wake = VIRT + (t or 0), started = false })
    return co
end

function task_mod.wait(t)
    coroutine.yield(VIRT + (t or 0))
end

local function pump(seconds)
    local deadline = VIRT + seconds
    while VIRT < deadline do
        VIRT = VIRT + 0.02
        local i = 1
        while i <= #tasks do
            local job = tasks[i]
            if job.wake <= VIRT then
                if coroutine.status(job.co) == "dead" then
                    table.remove(tasks, i)
                else
                    local ok, err
                    if not job.started then
                        job.started = true
                        ok, err = coroutine.resume(job.co, TUNPACK(job.args))
                    else
                        ok, err = coroutine.resume(job.co)
                    end
                    if not ok then
                        print("!! task error: " .. tostring(err))
                        table.remove(tasks, i)
                    elseif coroutine.status(job.co) == "dead" then
                        table.remove(tasks, i)
                    else
                        job.wake = VIRT + 0.02
                        i = i + 1
                    end
                end
            else
                i = i + 1
            end
        end
    end
end

--==============================================================================
-- Enum mock
--==============================================================================

local function enum_item(enum_name, item_name)
    return { Name = item_name, EnumType = enum_name, Value = 0 }
end

local ENUM_VALUES = {
    UserInputState = { Begin = 0, Change = 1, End = 2, Cancel = 3, None = 4 },
    RaycastFilterType = { Exclude = 0, Blacklist = 1 },
}

local Enum
do
    local ENUM_CACHE = {}
    Enum = setmetatable({}, {
        __index = function(_, enum_name)
            local cached = ENUM_CACHE[enum_name]
            if cached then return cached end
            local store = {}
            local values = ENUM_VALUES[enum_name] or {}
            local proxy = setmetatable({}, {
                __index = function(_, item_name)
                    local it = store[item_name]
                    if it then return it end
                    it = { Name = item_name, EnumType = enum_name, Value = values[item_name] or 0 }
                    store[item_name] = it
                    return it
                end,
            })
            ENUM_CACHE[enum_name] = proxy
            return proxy
        end,
    })
end

--==============================================================================
-- datatypes
--==============================================================================

local Vec3 = {}
Vec3.__index = Vec3
Vec3.__mul = function(a, b)
    return setmetatable({ X = a.X * b, Y = a.Y * b, Z = a.Z * b }, Vec3)
end
Vec3.__add = function(a, b)
    return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, Vec3)
end

local Vector3 = {
    new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vec3) end,
}

local Vec2 = {}
Vec2.__index = Vec2
Vec2.__sub = function(a, b) return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y }, Vec2) end
Vec2.__add = function(a, b) return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y }, Vec2) end

local Vector2 = {
    new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0 }, Vec2) end,
}

local Color3 = { fromRGB = function(r, g, b) return { R = r, G = g, B = b } end, new = function(r, g, b) return { R = r, G = g, B = b } end }
local UDim = { new = function(s, o) return { Scale = s, Offset = o } end }
local UDim2 = { new = function(a, b, c, d) return { X = { Scale = a, Offset = b }, Y = { Scale = c, Offset = d } } end }

--==============================================================================
-- json (harness side, real implementation)
--==============================================================================

local function json_encode(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.6f", v)
    end
    if t == "string" then
        return '"' .. v:gsub("[%c\"\\]", function(c)
            if c == '"' then return '\\"' end
            if c == "\\" then return "\\\\" end
            if c == "\n" then return "\\n" end
            if c == "\r" then return "\\r" end
            if c == "\t" then return "\\t" end
            return string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        local is_arr = true
        local n = 0
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" then is_arr = false end
        end
        if is_arr and n == #v then
            local parts = {}
            for i = 1, #v do parts[i] = json_encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function json_decode(s)
    local pos = 1
    local function skip()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local parse_value
    local function parse_string()
        pos = pos + 1
        local out = {}
        while pos <= #s do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local n = s:sub(pos + 1, pos + 1)
                if n == "n" then out[#out + 1] = "\n"
                elseif n == "t" then out[#out + 1] = "\t"
                elseif n == "r" then out[#out + 1] = "\r"
                elseif n == "u" then
                    local hex = s:sub(pos + 2, pos + 5)
                    out[#out + 1] = string.char(tonumber(hex, 16) % 256)
                    pos = pos + 4
                else out[#out + 1] = n end
                pos = pos + 2
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end
    local function parse_number()
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        pos = pos + #num
        return tonumber(num)
    end
    parse_value = function()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skip()
                local key = parse_string()
                skip()
                pos = pos + 1 -- ':'
                obj[key] = parse_value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then break end
            end
            return obj
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = parse_value()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then break end
            end
            return arr
        elseif c == '"' then
            return parse_string()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        else
            return parse_number()
        end
    end
    local ok, res = pcall(parse_value)
    if ok then return res end
    return nil
end

--==============================================================================
-- instance mock
--==============================================================================

local EVENT_NAMES = {
    InputBegan = true, InputChanged = true, InputEnded = true, Idled = true,
    DescendantAdded = true, ChildAdded = true, ChildRemoved = true,
    MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true,
    Activated = true, FocusLost = true, Loaded = true, Heartbeat = true,
    RenderStepped = true, Touched = true, PlaybackCompleted = true,
}

local GUI_CLASSES = {
    Frame = true, TextLabel = true, TextButton = true, TextBox = true, ImageLabel = true,
    ImageButton = true, ScrollingFrame = true, ScreenGui = true, UICorner = true,
    UIPadding = true, UIListLayout = true, CanvasGroup = true,
}

local INSTANCES = {}
local function newsignal()
    local conns = {}
    local sig = {}
    function sig:Connect(fn)
        local conn = { fn = fn }
        function conn:Disconnect() conn.dead = true end
        conns[#conns + 1] = conn
        return conn
    end
    function sig:Fire(...)
        for _, c in ipairs(conns) do
            if not c.dead then
                local ok, err = pcall(c.fn, ...)
                if not ok then print("!! signal handler error: " .. tostring(err)) end
            end
        end
    end
    function sig:Wait() return nil end
    return sig
end

local function new_instance(class, name)
    local o = {
        _class = class,
        _name = name or class,
        _children = {},
        _props = {},
        _signals = {},
        _parent = nil,
    }
    setmetatable(o, INSTANCES)
    return o
end

local METHODS = {}

function METHODS:GetChildren()
    local out = {}
    for i, c in ipairs(rawget(self, "_children")) do out[i] = c end
    return out
end

function METHODS:GetDescendants()
    local out = {}
    local function walk(node)
        for _, c in ipairs(rawget(node, "_children")) do
            out[#out + 1] = c
            walk(c)
        end
    end
    walk(self)
    return out
end

function METHODS:FindFirstChild(n)
    for _, c in ipairs(rawget(self, "_children")) do
        if rawget(c, "_name") == n then return c end
    end
    return nil
end

function METHODS:FindFirstChildOfClass(cls)
    for _, c in ipairs(rawget(self, "_children")) do
        if rawget(c, "_class") == cls then return c end
    end
    return nil
end

function METHODS:WaitForChild(n, t)
    return self:FindFirstChild(n)
end

function METHODS:IsA(cls)
    local c = rawget(self, "_class")
    if c == cls or cls == "Instance" then return true end
    if cls == "GuiObject" and GUI_CLASSES[c] then return true end
    if cls == "GuiButton" and (c == "TextButton" or c == "ImageButton") then return true end
    if cls == "ValueBase" and c:match("Value$") then return true end
    return false
end

function METHODS:GetFullName()
    local parts = {}
    local node = self
    while node do
        table.insert(parts, 1, rawget(node, "_name"))
        node = rawget(node, "_parent")
    end
    return table.concat(parts, ".")
end

function METHODS:GetAttributes()
    local props = rawget(self, "_props")
    return props.__attributes or {}
end

function METHODS:SetAttribute(k, v)
    local props = rawget(self, "_props")
    props.__attributes = props.__attributes or {}
    props.__attributes[k] = v
end

function METHODS:GetAttribute(k)
    return (rawget(self, "_props").__attributes or {})[k]
end

function METHODS:Destroy()
    local p = rawget(self, "_parent")
    if p then
        local kids = rawget(p, "_children")
        for i, c in ipairs(kids) do
            if c == self then table.remove(kids, i) break end
        end
    end
end

function METHODS:Clone()
    return new_instance(rawget(self, "_class"), rawget(self, "_name"))
end

INSTANCES = {
    __index = function(t, k)
        local props = rawget(t, "_props")
        local v = props[k]
        if v ~= nil then return v end
        if k == "Name" then return rawget(t, "_name") end
        if k == "ClassName" then return rawget(t, "_class") end
        if k == "Parent" then return rawget(t, "_parent") end
        if k == "Visible" then return true end
        if METHODS[k] then return METHODS[k] end
        local sigs = rawget(t, "_signals")
        if sigs[k] then return sigs[k] end
        if EVENT_NAMES[k] then
            local s = newsignal()
            sigs[k] = s
            return s
        end
        return nil
    end,
    __newindex = function(t, k, v)
        if k == "Parent" then
            local old = rawget(t, "_parent")
            if old then
                local kids = rawget(old, "_children")
                for i, c in ipairs(kids) do
                    if c == t then table.remove(kids, i) break end
                end
            end
            rawset(t, "_parent", v)
            if v then table.insert(rawget(v, "_children"), t) end
            return
        end
        if k == "Name" then rawset(t, "_name", v) return end
        local props = rawget(t, "_props")
        props[k] = v
    end,
}

local Instance = {
    new = function(...)
        local args = { ... }
        local class = args[1]
        local parent = nil
        local name = nil
        for i = 2, #args do
            if type(args[i]) == "table" and rawget(args[i], "_class") then
                parent = args[i]
            elseif type(args[i]) == "string" then
                name = args[i]
            end
        end
        local o = new_instance(class, name)
        if parent then o.Parent = parent end
        return o
    end,
}

--==============================================================================
-- service mocks
--==============================================================================

local files = {}
local clip = nil
local sim_calls = { touch = 0, mouse = 0, move = 0, key = 0 }
local HARNESS_FLAGS = {}

local PG = new_instance("PlayerGui", "PlayerGui")
local PLAYER = new_instance("Player", "TestPlayer")
PLAYER.Parent = new_instance("Players", "Players")
local players_service = PLAYER.Parent
players_service.LocalPlayer = PLAYER
PG.Parent = PLAYER
local GROUND = new_instance("Part", "GrassGround")

local function make_label(class, name, text, parent)
    local l = new_instance(class, name)
    l.Text = text
    l.Visible = true
    l.AbsolutePosition = Vector2.new(0, 0)
    l.AbsoluteSize = Vector2.new(100, 20)
    l.Parent = parent or PG
    return l
end

local wave_label = make_label("TextLabel", "WaveCounter", "Wave 3 / 25")
local cd_label = make_label("TextLabel", "WaveCountdown", "7")
local mode_label = make_label("TextButton", "ModeSelect", "Classic")
local diff_label = make_label("TextButton", "DifficultySelect", "Impossible")
local speed_label = make_label("TextButton", "SpeedToggle", "x3")
local seed_label = make_label("TextLabel", "SeedsDisplay", "1,250 Seeds")

local UIS_SIGNALS = {}
local UIS = new_instance("UserInputService", "UserInputService")
UIS.GetMouseLocation = function() return Vector2.new(50, 60) end

local CAM = new_instance("Camera", "Camera")
CAM.ViewportPointToRay = function(_, x, y)
    return { Origin = Vector3.new(0, 0, 0), Direction = Vector3.new(0, 0, -1) }
end
CAM.WorldToScreenPoint = function(_, v) return Vector3.new(120, 240, 0), true end

local WS = new_instance("Workspace", "Workspace")
WS.CurrentCamera = CAM
GROUND.Parent = WS
WS.Raycast = function(_, origin, dir, params)
    return { Position = Vector3.new(12.5, 0, -40.25), Instance = GROUND }
end

local UNITS = new_instance("Folder", "Units")
UNITS.Parent = WS
local unit_folder = new_instance("Folder", "TestPlayer")
unit_folder.Parent = UNITS

local RS = new_instance("ReplicatedStorage", "ReplicatedStorage")
do
    local re = new_instance("RemoteEvent", "RoundStartedEvent")
    re.Parent = RS
    local re2 = new_instance("RemoteEvent", "PlaceUnitRemote")
    re2.Parent = RS
end

local HttpService = new_instance("HttpService", "HttpService")
HttpService.JSONEncode = function(_, v) return json_encode(v) end
HttpService.JSONDecode = function(_, s) return json_decode(s) end

local StarterGui = new_instance("StarterGui", "StarterGui")
StarterGui.SetCore = function() end

local VirtualUser = new_instance("VirtualUser", "VirtualUser")
VirtualUser.ClickButton2 = function() end

local VIM = new_instance("VirtualInputManager", "VirtualInputManager")
VIM.SendMouseButtonEvent = function(_, x, y, btn, isDown)
    sim_calls.mouse = sim_calls.mouse + 1
    if HARNESS_FLAGS.on_mouse then HARNESS_FLAGS.on_mouse(isDown) end
end
VIM.SendMouseMoveEvent = function() sim_calls.move = sim_calls.move + 1 end
VIM.SendTouchEvent = function(_, id, state, x, y)
    sim_calls.touch = sim_calls.touch + 1
    if HARNESS_FLAGS.on_touch then HARNESS_FLAGS.on_touch(state) end
end
VIM.SendKeyEvent = function() sim_calls.key = sim_calls.key + 1 end

local SERVICES = {
    Players = players_service,
    UserInputService = UIS,
    RunService = new_instance("RunService", "RunService"),
    HttpService = HttpService,
    TweenService = new_instance("TweenService", "TweenService"),
    StarterGui = StarterGui,
    ReplicatedStorage = RS,
    VirtualUser = VirtualUser,
    VirtualInputManager = VIM,
    Workspace = WS,
    CoreGui = new_instance("CoreGui", "CoreGui"),
    ContextActionService = new_instance("ContextActionService", "CAS"),
}

local GAME = new_instance("DataModel", "Game")
GAME.PlaceId = 108533757090220
GAME.JobId = "harness-job-0001"
GAME.Loaded = newsignal()
GAME.GetService = function(_, n)
    if not SERVICES[n] then SERVICES[n] = new_instance(n, n) end
    return SERVICES[n]
end
GAME.IsLoaded = function() return true end
GAME.HttpGet = function(_, url) return "-- stub" end

-- services hang off the DataModel so resolve_path("Players.X.PlayerGui.Y") works
for name, svc in pairs(SERVICES) do
    if name ~= "CoreGui" then
        svc.Parent = GAME
    end
end
GAME.Name = ""   -- GetFullName() of a service must not carry a "Game." prefix

--==============================================================================
-- sandbox env
--==============================================================================

local GENV = {}
local env = setmetatable({}, { __index = _G })
env.game = GAME
env.workspace = WS
env.Instance = Instance
env.Enum = Enum
env.Vector3 = Vector3
env.Vector2 = Vector2
env.Color3 = Color3
env.UDim = UDim
env.UDim2 = UDim2
env.RaycastParams = { new = function() return { FilterType = nil, FilterDescendantsInstances = {}, IgnoreWater = false } end }
env.task = task_mod
env.os = { clock = function() return VIRT end, time = os.time, date = os.date, difficulty = 0 }
env.warn = function(...) print("[warn]", ...) end
env.typeof = function(v)
    if type(v) == "table" and rawget(v, "_class") then return "Instance" end
    return type(v)
end
env.getgenv = function() return GENV end
env.setclipboard = function(s) clip = s end
env.writefile = function(p, d) files[p] = d end
env.readfile = function(p) if files[p] == nil then error("file not found: " .. p) end return files[p] end
env.isfile = function(p) return files[p] ~= nil end
env.isfolder = function(p)
    for k in pairs(files) do if k:sub(1, #p) == p then return true end end
    return false
end
env.makefolder = function() end
env.delfile = function(p) files[p] = nil end
env.delfolder = function() end
env.listfiles = function(p)
    local out = {}
    for k in pairs(files) do if k:sub(1, #p) == p then out[#out + 1] = k end end
    return out
end
env.gethui = nil
-- two variants: a bare executor (no hook, spy disabled) and one with hookmetamethod
local RAW_MT = { __namecall = function() return nil end }
if WITH_SPY then
    env.getnamecallmethod = function() return "FireServer" end
    env.newcclosure = function(fn) return fn end
    env.getrawmetatable = function() return RAW_MT end
    env.setreadonly = function() end
    env.hookmetamethod = function() end
else
    env.hookmetamethod = nil      -- executors without it: the no-spy path gets tested
    env.getrawmetatable = nil
    env.newcclosure = nil
    env.getnamecallmethod = nil
end
env.mousemoveabs = function() sim_calls.move = sim_calls.move + 1 end
env.mouse1click = function() sim_calls.mouse = sim_calls.mouse + 1 end
env.mouse1press = function() sim_calls.mouse = sim_calls.mouse + 1 end
env.mouse1release = function() sim_calls.mouse = sim_calls.mouse + 1 end
env.firesignal = nil
env.getconnections = nil
env.setreadonly = function() end
env.syn = nil

--==============================================================================
-- run
--==============================================================================

local f = assert(io.open(MAIN_PATH, "r"))
local src = f:read("*a")
f:close()

local chunk, err = load(src, "@Main.lua", "t", env)
if not chunk then
    print("COMPILE FAIL: " .. tostring(err))
    os.exit(1)
end

local ok, API = pcall(chunk)
if not ok then
    print("BOOT FAIL: " .. tostring(API))
    os.exit(1)
end
print("boot ok, api keys: " .. tostring(API and "yes" or "no"))

local failures = 0
local function check(name, cond, extra)
    if cond then
        print(string.format("  PASS  %s", name))
    else
        failures = failures + 1
        print(string.format("  FAIL  %s %s", name, extra and ("-> " .. tostring(extra)) or ""))
    end
end

-- 1. context detection
local PROBE = API.probe
local ctx = PROBE.detect_context()
print("\n[context]")
print("  mode=" .. tostring(ctx.mode) .. " diff=" .. tostring(ctx.difficulty)
    .. " speed=" .. tostring(ctx.speed) .. " waves=" .. tostring(ctx.wave_cur) .. "/" .. tostring(ctx.wave_total)
    .. " map_sig=" .. tostring(ctx.map_sig) .. " seeds=" .. tostring(ctx.seeds) .. " cd=" .. tostring(ctx.countdown))
check("mode detected", ctx.mode == "Classic", ctx.mode)
check("difficulty detected", ctx.difficulty == "Impossible", ctx.difficulty)
check("speed detected", ctx.speed == 3, ctx.speed)
check("wave counter parsed", ctx.wave_cur == 3 and ctx.wave_total == 25, tostring(ctx.wave_cur) .. "/" .. tostring(ctx.wave_total))
check("countdown parsed", ctx.countdown == 7, ctx.countdown)
check("map signature non nil", type(ctx.map_sig) == "number", ctx.map_sig)

-- 2. remotes + loadout + containers
local remotes = PROBE.scan_remotes()
print("\n[remotes] top: " .. tostring(remotes[1] and remotes[1].name) .. " score=" .. tostring(remotes[1] and remotes[1].score))
check("remote scan found candidates", #remotes >= 2, #remotes)
check("wave-ish remote scored highest", remotes[1] and remotes[1].score >= 3, remotes[1] and remotes[1].score)

local units, src = PROBE.loadout()
check("loadout scan runs", type(units) == "table", "?")
print("  loadout src: " .. tostring(src))

local sig, parts = PROBE.map_signature()
check("workspace parts listed", #parts > 0 and type(sig) == "number", #parts)

-- 3. record flow
print("\n[recording]")
local REC = API.recorder
local ok_start = REC.start()
check("REC.start()", ok_start == true, ok_start)
pump(0.3)  -- let the wave watcher take its first sample

local function fire_input(sig, x, y, utype)
    sig:Fire({
        UserInputType = Enum.UserInputType[utype or "Touch"],
        Position = { X = x, Y = y, Z = 0 },
        KeyCode = Enum.KeyCode.A,
    }, false)
end

-- placement tap
fire_input(UIS.InputBegan, 300, 500, "Touch")
fire_input(UIS.InputEnded, 300, 500, "Touch")
-- upgrade tap on a gui button
fire_input(UIS.InputBegan, 120, 240, "MouseButton1")
fire_input(UIS.InputEnded, 120, 240, "MouseButton1")
-- drag
fire_input(UIS.InputBegan, 400, 600, "Touch")
fire_input(UIS.InputChanged, 420, 620, "Touch")
fire_input(UIS.InputChanged, 460, 660, "Touch")
fire_input(UIS.InputEnded, 460, 660, "Touch")
-- key
fire_input(UIS.InputBegan, 0, 0, "Keyboard")
fire_input(UIS.InputEnded, 0, 0, "Keyboard")

pump(2.0)

check("steps recorded", REC.step_count() >= 8, REC.step_count())
local macro, save_err = REC.finalize("harness run", true)
check("macro finalized", macro ~= nil, save_err)
if macro then
    print("  steps=" .. #macro.steps .. " duration=" .. string.format("%.2f", macro.duration)
        .. " ctx=" .. tostring(macro.ctx.mode) .. "/" .. tostring(macro.ctx.difficulty)
        .. " speed=x" .. tostring(macro.ctx.speed) .. " start_wave=" .. tostring(macro.ctx.start_wave))
    check("macro stamped with speed", macro.ctx.speed == 3, macro.ctx.speed)
    check("macro stamped with map label", type(macro.ctx.map_label) == "string", macro.ctx.map_label)
    check("down step carries world point", macro.steps[1] and macro.steps[1].world ~= nil)
    check("step carries wave + dt", macro.steps[1] and macro.steps[1].wave ~= nil)
end

-- 4. store round trip
print("\n[store]")
local STORE = API.store
local entries = STORE.sorted_entries()
check("index has the macro", #entries >= 1, #entries)
check("index entry pinned", entries[1] and entries[1].pinned == true)
local loaded = macro and STORE.load_macro(macro.id)
check("macro loads back", loaded ~= nil and #loaded.steps == #macro.steps)
STORE.pin(macro.id, false)
check("unpin persists", STORE.entry_of(macro.id).pinned == false)
STORE.rename(macro.id, "renamed run")
check("rename persists", STORE.entry_of(macro.id).name == "renamed run")

local raw = json_encode(loaded)
check("macro json non trivial", #raw > 200, #raw)

-- 5. compat + play (same context first, so the playback actually runs)
print("\n[playback]")
local compat, curctx = API.player.compat(loaded)
check("compat silent on same context", #compat == 0, table.concat(compat, "; "))

local okp, a, b = API.player.run(loaded, { loops = 1, force = true })
check("PLAY.run accepted", okp == true, tostring(a))
pump(12)
check("sim input happened", (sim_calls.mouse + sim_calls.touch) > 0,
    string.format("mouse=%d touch=%d move=%d key=%d", sim_calls.mouse, sim_calls.touch, sim_calls.move, sim_calls.key))
local st = API.state
print("  stats: steps=" .. tostring(st.stat.step) .. "/" .. tostring(st.stat.total)
    .. " late=" .. tostring(st.stat.late) .. " missed=" .. tostring(st.stat.missed)
    .. " verified=" .. tostring(st.stat.verified) .. " failed=" .. tostring(st.stat.failed)
    .. " timeouts=" .. tostring(st.stat.timeouts) .. " skipped=" .. tostring(st.stat.skipped))
check("playback finished", st.playing == false, tostring(st.playing))
check("no steps were skipped on a clean run", (st.stat.skipped or 0) == 0, st.stat.skipped)
check("no wave timeouts on a clean run", (st.stat.timeouts or 0) == 0, st.stat.timeouts)

-- now break the context: the history stamp must show it
mode_label.Text = "Survival"
speed_label.Text = "x1"
wave_label.Text = "Wave 1 / 40"
local compat2 = API.player.compat(loaded)
print("  mismatches now: " .. table.concat(compat2, " | "))
check("mismatch detected on mode/speed/waves", #compat2 >= 2, #compat2)
check("speed-mode block would refuse", (function()
    local keep = API.config.speed_mode
    API.config.speed_mode = "block"
    local okb = API.player.run(loaded, { loops = 1 })
    API.config.speed_mode = keep
    return okb == false
end)())

-- speed scaling: recorded x3, now x1 -> scale must be 3
local scale_ok = false
do
    local ok2, sc = API.player.run({ name = "x", ctx = { speed = 3, place_id = GAME.PlaceId }, steps = {}, anchors = {} },
        { loops = 1, force = true })
    if ok2 and sc == 3 then scale_ok = true end
end
check("speed scale = rec/now", scale_ok)
pump(1)

-- 6. ui paths
print("\n[ui]")
local UI = API.ui
UI.status()
UI.refresh_macros()
UI.toast("harness toast")
check("ui contains_point callable", API.ui ~= nil and type(API.probe) == "table")
check("state exported to genv", GENV.ANON_GTD ~= nil)

-- 7. discovery report path used by the SETUP tab
local setup_ok = pcall(function()
    local c = API.probe.detect_context()
    local u = API.probe.loadout()
    local r = API.probe.scan_remotes()
    return c, u, r
end)
check("setup tab code paths", setup_ok == true, setup_ok)

--==============================================================================
-- 8. wave anchor precision  (the load bearing claim: fixed to the round, not to the clock)
--==============================================================================

print("\n[wave anchor]")
STORE.profile.wave_path = wave_label:GetFullName()
check("pinned wave path resolves", API.repair.resolve_path(STORE.profile.wave_path) ~= nil,
    STORE.profile.wave_path)

speed_label.Text = "x1"
wave_label.Text = "Wave 8 / 25"
pump(2.2)   -- idle watcher picks the counter up
check("watcher follows the wave counter", API.state.wave == 8, API.state.wave)

-- deterministic T0 for the timing assertions (the same call the SETUP tab makes)
API.player.mark_wave(8)
check("T0 recorded on wave change", API.state.wave_t0 ~= nil, API.state.wave_t0)

local anchor_macro = {
    id = "anchor-test", name = "anchor test", created = os.time(), duration = 3,
    ctx = { place_id = GAME.PlaceId, speed = 1, start_wave = 8, mode = "Classic", difficulty = "Impossible" },
    anchors = {},
    steps = {
        { kind = "key", code = "Space", pressed = true, wave = 8, dt = 0.30, t_abs = 0.30 },
        { kind = "down", wave = 8, dt = 1.00, t_abs = 1.00, x = 500, y = 600, itype = "Touch", world = { x = 1, y = 0, z = 1 } },
        { kind = "up", wave = 8, dt = 1.20, t_abs = 1.20, x = 500, y = 600, itype = "Touch", world = { x = 1, y = 0, z = 1 } },
        { kind = "down", wave = 8, dt = 2.00, t_abs = 2.00, x = 120, y = 240, itype = "MouseButton1" },
        { kind = "up", wave = 8, dt = 2.10, t_abs = 2.10, x = 120, y = 240, itype = "MouseButton1" },
    },
}

local touch0, mouse0, key0 = sim_calls.touch, sim_calls.mouse, sim_calls.key
local okr = API.player.run(anchor_macro, { loops = 1, force = true })
check("anchor playback accepted", okr == true)

pump(0.15)
check("nothing taps before its dt", sim_calls.touch == touch0 and sim_calls.key == key0,
    string.format("touch+%d key+%d", sim_calls.touch - touch0, sim_calls.key - key0))
pump(0.25)   -- ~0.40s since T0 > 0.30
check("key step fired on its dt", sim_calls.key > key0, sim_calls.key - key0)
pump(0.40)   -- ~0.80s < 1.00
check("touch still not fired at 0.80s", sim_calls.touch == touch0, sim_calls.touch - touch0)
pump(0.40)   -- ~1.20s
check("touch pair fired after its dt", sim_calls.touch > touch0, sim_calls.touch - touch0)
pump(0.60)   -- ~1.80s < 2.00
check("mouse still not fired at 1.80s", sim_calls.mouse == mouse0, sim_calls.mouse - mouse0)
pump(0.50)   -- ~2.30s > 2.10
check("mouse pair fired on its own dt", sim_calls.mouse > mouse0, sim_calls.mouse - mouse0)
pump(0.50)
check("no late dispatches", (API.state.stat.late or 0) == 0, API.state.stat.late)
check("no missed waves", (API.state.stat.missed or 0) == 0, API.state.stat.missed)
check("anchor playback finished", API.state.playing == false)

--==============================================================================
-- 8b. round alignment: start wave behind the macro's start wave
--==============================================================================

print("\n[wave align]")
speed_label.Text = "x1"
wave_label.Text = "Wave 2 / 25"
pump(2.2)
check("counter is behind the macro start", API.state.wave == 2, API.state.wave)

local align_macro = {
    id = "align-test", name = "align test", created = os.time(), duration = 1,
    ctx = { place_id = GAME.PlaceId, speed = 1, start_wave = 4 },
    anchors = {},
    steps = {
        { kind = "down", wave = 4, dt = 0.20, t_abs = 0.20, x = 10, y = 10, itype = "Touch" },
        { kind = "up", wave = 4, dt = 0.30, t_abs = 0.30, x = 10, y = 10, itype = "Touch" },
    },
}
local t0c = sim_calls.touch
API.player.run(align_macro, { loops = 1, force = true })
pump(2)
check("holds while the round is behind", sim_calls.touch == t0c, sim_calls.touch - t0c)
check("still playing while holding", API.state.playing == true, tostring(API.state.playing))
wave_label.Text = "Wave 4 / 25"
pump(4)
check("fires once the round catches up", sim_calls.touch > t0c, sim_calls.touch - t0c)
pump(2)
check("align run finished", API.state.playing == false, tostring(API.state.playing))

--==============================================================================
-- 8c. a wave that never arrives: skip, never tap at the wrong moment
--==============================================================================

print("\n[wave timeout skip]")
local keep_timeout = API.config.wave_timeout
API.config.wave_timeout = 2
wave_label.Text = "Wave 5 / 25"
pump(0.4)

local skip_macro = {
    id = "skip-test", name = "skip test", created = os.time(), duration = 1,
    ctx = { place_id = GAME.PlaceId, speed = 1, start_wave = 5 },
    anchors = {},
    steps = {
        { kind = "down", wave = 20, dt = 0.10, t_abs = 0.10, x = 11, y = 11, itype = "Touch" },
        { kind = "up", wave = 20, dt = 0.20, t_abs = 0.20, x = 11, y = 11, itype = "Touch" },
    },
}
local t1c = sim_calls.touch
API.player.run(skip_macro, { loops = 1, force = true })
pump(8)
check("nothing tapped for the missing wave", sim_calls.touch == t1c, sim_calls.touch - t1c)
check("steps counted as skipped", (API.state.stat.skipped or 0) == 2, API.state.stat.skipped)
check("timeouts counted", (API.state.stat.timeouts or 0) == 2, API.state.stat.timeouts)
check("run ended after skipping", API.state.playing == false, tostring(API.state.playing))
API.config.wave_timeout = keep_timeout

--==============================================================================
-- 9. placement verification + retry
--==============================================================================

print("\n[placement verify]")
STORE.profile.container_path = unit_folder:GetFullName()
check("unit container resolves", API.repair.resolve_path(STORE.profile.container_path) ~= nil,
    STORE.profile.container_path)

wave_label.Text = "Wave 5 / 25"
pump(2.2)
check("counter synced for the place test", API.state.wave == 5, API.state.wave)

local place_macro = {
    id = "place-test", name = "place test", created = os.time(), duration = 1,
    ctx = { place_id = GAME.PlaceId, speed = 1, start_wave = 5 },
    anchors = { container_path = unit_folder:GetFullName() },
    steps = {
        { kind = "down", wave = 5, dt = 0.10, t_abs = 0.10, x = 400, y = 500, itype = "Touch", world = { x = 2, y = 0, z = 2 } },
        { kind = "up", wave = 5, dt = 0.20, t_abs = 0.20, x = 400, y = 500, itype = "Touch", world = { x = 2, y = 0, z = 2 } },
    },
}

HARNESS_FLAGS.on_touch = function(state)
    if state == Enum.UserInputState.End.Value and HARNESS_FLAGS.place_ok then
        local model = new_instance("Model", "Bloodvine")
        model.Parent = unit_folder
    end
end

local before_children = #unit_folder._children
HARNESS_FLAGS.place_ok = true
API.player.run(place_macro, { loops = 1, force = true })
pump(4)
check("placement verified when the unit lands", (API.state.stat.verified or 0) == 1,
    "verified=" .. tostring(API.state.stat.verified) .. " failed=" .. tostring(API.state.stat.failed))
check("unit actually added", #unit_folder._children > before_children)

HARNESS_FLAGS.place_ok = false
API.player.run(place_macro, { loops = 1, force = true })
pump(6)
check("placement marked failed when nothing lands", (API.state.stat.failed or 0) == 1,
    "verified=" .. tostring(API.state.stat.verified) .. " failed=" .. tostring(API.state.stat.failed))

--==============================================================================
-- 10. store durability across a simulated rejoin
--==============================================================================

print("\n[durability]")
local entries2 = STORE.sorted_entries()
check("index survives with context columns", #entries2 >= 1
    and entries2[1].mode ~= nil and entries2[1].speed ~= nil, #entries2)
local profile_raw = files[API.config.root_dir .. "/profile.json"]
check("profile written to disk", type(profile_raw) == "string" and #profile_raw > 10)
local macro_files = 0
for path in pairs(files) do
    if path:find("/macros/", 1, true) then macro_files = macro_files + 1 end
end
check("macro json files on disk", macro_files >= 1, macro_files)

--==============================================================================
-- 11. remote spy (only meaningful on the WITH_SPY variant)
--==============================================================================

if WITH_SPY then
    print("\n[remote spy]")
    check("spy reported available", API.probe.spy_supported == true)
    local remote_ev = RS:FindFirstChild("RoundStartedEvent")
    check("remote instance present", remote_ev ~= nil)
    if remote_ev and RAW_MT.__namecall then
        RAW_MT.__namecall(remote_ev, "wave", 4, true)
        RAW_MT.__namecall(remote_ev, "wave", 5, true)
    end
    local entry = API.probe.spy_log["RoundStartedEvent"]
    check("fire logged by the hook", entry ~= nil and entry.count >= 2, entry and entry.count)
    check("args preview captured", entry ~= nil and entry.samples[1] ~= nil, entry and entry.samples[1])
    if entry then print("  sample: " .. tostring(entry.samples[1])) end
end

--==============================================================================
-- 12. ui: collapse + restore, and the colour contrast audit
--==============================================================================

print("\n[ui collapse]")
local ui = API.ui
check("ui handles exported", ui.root ~= nil and ui.main ~= nil and ui.mini ~= nil)
check("mini bar lives in the screen gui, not in the panel", ui.mini.Parent == ui.root)

local min_btn, close_btn
for _, d in ipairs(ui.root:GetDescendants()) do
    if d.ClassName == "TextButton" then
        if d.Text == "—" then min_btn = d end
        if d.Text == "x" then close_btn = d end
    end
end
check("minimize button found", min_btn ~= nil)
check("close button found", close_btn ~= nil)

if min_btn then
    min_btn.MouseButton1Click:Fire()
    check("panel collapses to the mini bar", ui.main.Visible == false and ui.mini.Visible == true,
        string.format("main=%s mini=%s", tostring(ui.main.Visible), tostring(ui.mini.Visible)))
    ui.mini.MouseButton1Click:Fire()
    check("mini bar brings the panel back", ui.main.Visible == true and ui.mini.Visible == false,
        string.format("main=%s mini=%s", tostring(ui.main.Visible), tostring(ui.mini.Visible)))
end
if close_btn then
    close_btn.MouseButton1Click:Fire()
    check("close collapses, never kills the ui", ui.main.Visible == false and ui.mini.Visible == true
        and ui.root.Enabled ~= false, string.format("main=%s mini=%s enabled=%s",
        tostring(ui.main.Visible), tostring(ui.mini.Visible), tostring(ui.root.Enabled)))
    ui.mini.MouseButton1Click:Fire()
    check("restored after close", ui.main.Visible == true)
end

-- our own widgets must swallow taps so the recorder never records them
ui.collapse()
ui.mini.AbsolutePosition = Vector2.new(24, 90)
ui.mini.AbsoluteSize = Vector2.new(140, 26)
check("mini bar counts as our own ui (collapsed)", ui.contains_point(30, 95) == true)
ui.mini.MouseButton1Click:Fire()
ui.main.AbsolutePosition = Vector2.new(24, 90)
ui.main.AbsoluteSize = Vector2.new(400, 366)
check("open panel counts as our own ui", ui.contains_point(200, 200) == true)
check("empty space is not our ui", ui.contains_point(2, 2) == false)

print("\n[contrast]")
local function report(list, tag)
    for _, o in ipairs(list) do
        print(string.format("   %s  %.2f:1  %q  visible=%s", tag, o.ratio, o.text, tostring(o.visible)))
    end
end

local boot_bad = ui.audit_contrast()
report(boot_bad, "low")
check("no low contrast text at boot", #boot_bad == 0, #boot_bad)

-- every button that only flips a value: press each one and re-audit the whole tree
local SAFE_LABELS = {
    ["scale"] = true, ["block"] = true, ["auto"] = true, ["ui"] = true, ["touch"] = true,
    ["mouse"] = true, ["ON"] = true, ["OFF"] = true, ["0"] = true, ["1"] = true, ["2"] = true,
    ["4"] = true, ["5"] = true, ["25"] = true, ["inf"] = true, ["1.5s"] = true, ["0.8s"] = true,
    ["2.5s"] = true, ["4.0s"] = true, ["20s"] = true, ["45s"] = true, ["90s"] = true,
    ["180s"] = true, ["0ms"] = true, ["10ms"] = true, ["25ms"] = true, ["50ms"] = true,
    ["file API"] = true, ["memory"] = true,
    ["pinned only: ON"] = true, ["pinned only: OFF"] = true,
    ["pin on save: ON"] = true, ["pin on save: OFF"] = true,
}

local clicked, offenders = 0, {}
for _, entry in ipairs(ui.buttons or {}) do
    if SAFE_LABELS[entry.text] then
        pcall(function() entry.obj.MouseButton1Click:Fire() end)
        clicked = clicked + 1
        for _, o in ipairs(ui.audit_contrast()) do
            offenders[#offenders + 1] = o
        end
    end
end
check("flipped config buttons", clicked >= 8, clicked)
report(offenders, "low")
check("no low contrast text after flipping every toggle", #offenders == 0, #offenders)

--==============================================================================
-- 13. "recorded but nothing showed up" — the exact class of bug, as regression tests
--==============================================================================

print("\n[record: taps that only hit our own panel]")
-- the contrast section clicks every ON/OFF button, so pin the setting the rest of
-- this section depends on
API.config.auto_collapse_on_record = true
-- park the mini bar over the tap point: while recording that is the only widget on
-- screen, and a tap on our own ui must never become a recorded step
API.ui.mini.AbsolutePosition = Vector2.new(200, 400)
API.ui.mini.AbsoluteSize = Vector2.new(400, 400)
check("REC.start() collapses the panel for recording",
    (function()
        local ok = API.recorder.start()
        return ok == true and API.ui.main.Visible == false and API.ui.mini.Visible == true
    end)(),
    string.format("main=%s mini=%s", tostring(API.ui.main.Visible), tostring(API.ui.mini.Visible)))
pump(0.3)
fire_input(UIS.InputBegan, 300, 500, "Touch")
fire_input(UIS.InputEnded, 300, 500, "Touch")
pump(0.5)
local m2, err2 = API.recorder.finalize("empty test", false)
check("a zero-step save is refused", m2 == nil, m2 and (#m2.steps))
check("the reason names the panel", tostring(err2):find("panel") ~= nil, err2)
local cnt = API.recorder.counters()
check("counters saw the tap", (cnt.began or 0) >= 1, cnt.began)
check("counters saw the skip", (cnt.own_ui or 0) >= 2, cnt.own_ui)
check("empty-save reason is exported to the ui", API.recorder.last_report ~= nil)
API.ui.mini.AbsolutePosition = Vector2.new(24, 90)
API.ui.mini.AbsoluteSize = Vector2.new(140, 26)

print("\n[record: save report]")
API.recorder.start()
pump(0.3)
fire_input(UIS.InputBegan, 700, 200, "Touch")
fire_input(UIS.InputEnded, 700, 200, "Touch")
pump(0.6)
local m3, e3, rep3 = API.recorder.finalize("diag test", false)
check("saved", m3 ~= nil, tostring(e3))
check("save report carries the counters", rep3 ~= nil and rep3:find("taps seen") ~= nil, rep3)
check("report names the storage", rep3 ~= nil and rep3:find("storage") ~= nil)
check("entry is in the history", API.store.entry_of(m3.id) ~= nil)
print("  report: " .. tostring(rep3))

print("\n[disk write failure -> memory only]")
local orig_writefile = env.writefile
env.writefile = function(p, d)
    if string.find(p, "macros/", 1, true) then error("simulated: disk full") end
    return orig_writefile(p, d)
end
API.recorder.start()
pump(0.3)
fire_input(UIS.InputBegan, 640, 260, "Touch")
fire_input(UIS.InputEnded, 640, 260, "Touch")
pump(0.6)
local m4, e4 = API.recorder.finalize("disk full test", false)
env.writefile = orig_writefile
check("macro still registered when the disk refuses", m4 ~= nil, tostring(e4))
check("entry flagged memory only", m4 and API.store.entry_of(m4.id).memory_only == true)
check("still loadable this session", m4 and API.store.load_macro(m4.id) ~= nil)
check("save note mentions memory", tostring(e4):find("memory") ~= nil, e4)

print("\n[index rebuild from disk]")
local orphan = {
    id = "orphan-test", name = "orphan", created = os.time(), duration = 1,
    ctx = { mode = "Classic", difficulty = "Easy", speed = 1, map = "Dojo", loadout = { "Corn" } },
    steps = { { kind = "down", wave = 1, dt = 0.1, t_abs = 0.1, x = 1, y = 1, itype = "Touch" } },
}
files["ANON_GTD/macros/orphan-test.json"] = json_encode(orphan)
API.store.init()
local oe = API.store.entry_of("orphan-test")
check("orphan macro recovered into the index", oe ~= nil, oe and oe.recovered)
check("recovered entry keeps its context stamp", oe ~= nil and oe.mode == "Classic" and oe.map == "Dojo",
    oe and (tostring(oe.mode) .. "/" .. tostring(oe.map)))
check("recovered macro is loadable", API.store.load_macro("orphan-test") ~= nil)
local diag_text, counts = API.store.diagnose()
check("diagnose reports files, entries, memory-only",
    counts.files >= 2 and counts.entries >= 2 and counts.memory_only >= 1, json_encode(counts))
print("  " .. diag_text:gsub("\n", "\n  "))

print("\n=====================================")
print(string.format("FAILURES: %d", failures))
print("=====================================")
os.exit(failures == 0 and 0 or 1)
