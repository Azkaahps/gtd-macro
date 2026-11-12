--[[
    ANON GTD · loader check
    Drives the real Loader.lua against a mocked executor surface to prove the
    freshness and fallback rules:

      A fresh raw wins            D no source at all -> hard error
      B stale raw never downgrades a newer cache
      C raw down -> disk cache    E html/block page -> jsDelivr mirror
      F wrong game -> loader refuses to run
      G a stale fetch must not overwrite a newer cached copy

    Usage: luajit tools/loader_check.lua
--]]

local HERE = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "."
local LOADER_PATH = HERE .. "/../Loader.lua"

local fails = 0
local function check(name, ok, extra)
    if ok then
        print(string.format("  PASS  %s", name))
    else
        fails = fails + 1
        print(string.format("  FAIL  %s %s", name, extra and ("-> " .. tostring(extra)) or ""))
    end
end

local function read_file(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local loader_src = read_file(LOADER_PATH)

-- a stand-in for Main.lua: >500 bytes, carries a version stamp, records that it ran
local function payload(v, marker)
    return string.format([==[
local VERSION = "%s"
local CONFIG = { version = "%s", marker = "%s" }
local g = getgenv()
g.__RAN = g.__RAN or {}
table.insert(g.__RAN, "%s")
%s
return { version = CONFIG.version, marker = CONFIG.marker }
]==], v, v, marker or v, marker or v,
        string.rep("-- padding so the payload passes the size sanity check\n", 14))
end

local HTML = "<!DOCTYPE html><html><body>blocked by proxy</body></html>" .. string.rep(" ", 600)

local function version_hint(src)
    if type(src) ~= "string" then return nil end
    return src:match('version%s*=%s*"([%d%.]+)"') or src:match('VERSION%s*=%s*"([%d%.]+)"')
end

local GENV

local function run_loader(scenario)
    GENV = { __RAN = {} }
    local files = {}
    for k, v in pairs(scenario.files or {}) do files[k] = v end
    local warns = {}

    local env = setmetatable({}, { __index = _G })
    env.getgenv = function() return GENV end
    env.warn = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        warns[#warns + 1] = table.concat(parts, " ")
    end
    env.loadstring = function(src, name) return load(src, name, "t", env) end
    env.writefile = function(p, d) files[p] = d end
    env.readfile = function(p)
        if files[p] == nil then error("no such file: " .. tostring(p)) end
        return files[p]
    end
    env.isfile = function(p) return files[p] ~= nil end
    env.isfolder = function(p)
        for k in pairs(files) do if k:sub(1, #p) == p then return true end end
        return false
    end
    env.makefolder = function() end
    env.delfile = function(p) files[p] = nil end
    env.os = { time = function() return 1000 end, date = os.date }
    env.game = {
        PlaceId = scenario.place or 108533757090220,
        IsLoaded = function() return true end,
        Loaded = { Wait = function() end },
        HttpGet = function(_, url)
            if scenario.http then return scenario.http(url) end
            error("no http mock")
        end,
    }

    local chunk = assert(load(loader_src, "@Loader.lua", "t", env))
    local ok, res = pcall(chunk)
    return { ok = ok, res = res, files = files, warns = warns, ran = GENV.__RAN }
end

local RAW = "raw.githubusercontent.com"
local CDN = "cdn.jsdelivr.net"

--------------------------------------------------------------------------------
print("[A] fresh raw wins, cache gets written")
local A = run_loader({
    http = function(url)
        if url:find(RAW, 1, true) then return payload("1.0.1") end
        return nil
    end,
})
check("A runs", A.ok, A.res)
check("A returned the payload api", type(A.res) == "table" and A.res.version == "1.0.1", A.res and A.res.version)
check("A executed the raw build", A.ran[1] == "1.0.1", table.concat(A.ran, ","))
check("A cached the payload", A.files["ANON_GTD/Main.lua"] ~= nil)
check("A wrote the version stamp", A.files["ANON_GTD/version.txt"] == "1.0.1", A.files["ANON_GTD/version.txt"])

print("\n[B] stale raw must never downgrade a newer cache")
local B = run_loader({
    files = { ["ANON_GTD/Main.lua"] = payload("1.0.1") },
    http = function(url)
        if url:find(RAW, 1, true) then return payload("1.0.0") end   -- CDN lag
        return nil
    end,
})
check("B runs", B.ok, B.res)
check("B ran the cached newer build", B.ran[1] == "1.0.1", table.concat(B.ran, ","))
check("B kept the cached copy on disk", version_hint(B.files["ANON_GTD/Main.lua"]) == "1.0.1",
    version_hint(B.files["ANON_GTD/Main.lua"]))
local note = table.concat(B.warns, " | ")
check("B said why in the console", note:find("kept newer cached") ~= nil, note)

print("\n[C] github down -> disk cache")
local C = run_loader({
    files = { ["ANON_GTD/Main.lua"] = payload("1.0.1") },
    http = function() error("connection refused") end,
})
check("C runs", C.ok, C.res)
check("C used the cache", C.ran[1] == "1.0.1", table.concat(C.ran, ","))
check("C reported the mirror attempt", table.concat(C.warns, " | "):find("jsDelivr") ~= nil)

print("\n[D] nothing reachable and no cache -> hard error")
local D = run_loader({ http = function() error("connection refused") end })
check("D fails loudly", D.ok == false)
check("D error message is actionable",
    tostring(D.res):find("could not fetch Main.lua") ~= nil, D.res)

print("\n[E] block page -> jsDelivr mirror")
local E = run_loader({
    http = function(url)
        if url:find(RAW, 1, true) then return HTML end
        if url:find(CDN, 1, true) then return payload("1.0.1", "mirror") end
        return nil
    end,
})
check("E runs", E.ok, E.res)
check("E ran the mirror build", E.res and E.res.version == "1.0.1" and E.res.marker == "mirror",
    E.res and (tostring(E.res.version) .. "/" .. tostring(E.res.marker)))
check("E ignored the html payload", E.ran[1] == "mirror", table.concat(E.ran, ","))

print("\n[F] wrong game -> loader refuses")
local F = run_loader({ place = 1, http = function() return payload("1.0.1") end })
check("F returns without loading", F.ok == true and F.res == nil, F.res)
check("F did not execute anything", #F.ran == 0, #F.ran)

print("\n[G] broken live payload -> cached copy still boots")
local broken_live = payload("1.0.0"):sub(1, 300) .. "\nlocal broken = (((\n" .. string.rep("-- pad\n", 70)
check("G payload really is broken", load(broken_live) == nil)
local G = run_loader({
    files = { ["ANON_GTD/Main.lua"] = payload("1.0.0") },
    http = function(url)
        if url:find(RAW, 1, true) then return broken_live end
        return nil
    end,
})
check("G runs", G.ok, G.res)
check("G recovered from the cache", G.res and G.res.version == "1.0.0", G.res and G.res.version)

print("\n=====================================")
print(string.format("LOADER FAILURES: %d", fails))
print("=====================================")
os.exit(fails == 0 and 0 or 1)
