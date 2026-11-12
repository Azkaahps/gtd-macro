--[[
================================================================================
  ANON · Garden Tower Defense — loader  (v1.0.1)

  Paste this in Delta / any executor:

      loadstring(game:HttpGet("https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main/Loader.lua"))()

  It pulls Main.lua from GitHub raw (jsDelivr mirror as fallback), keeps a copy on
  disk, and refuses to run an older build than the one already cached -- GitHub's
  raw CDN lags behind a push by a few minutes, and a stale download must never
  downgrade the copy you already have.

  ------------------------------------------------------------------- setup
  1. push Main.lua to a PUBLIC repo, note user/repo and the branch (main)
  2. edit REPO / MIRROR below to match
  3. bump VERSION here only when this loader itself changes
================================================================================
--]]

local VERSION = "1.0.1"
local REPO    = "https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main"
local MIRROR  = "https://cdn.jsdelivr.net/gh/Azkaahps/gtd-macro@main"

local PLACES = {
    [108533757090220] = "Garden Tower Defense",
    [123516946198836] = "Garden Tower Defense (2)",
}

local CACHE_FILE = "ANON_GTD/Main.lua"

if not game:IsLoaded() then game.Loaded:Wait() end

local place_name = PLACES[game.PlaceId]
if not place_name then
    warn(string.format("[ANON GTD] this is not Garden Tower Defense (place %s). loader stopped.", tostring(game.PlaceId)))
    return
end

local env = getgenv()
if env.__ANON_GTD_BUSY then
    warn("[ANON GTD] loader already running")
    return
end
env.__ANON_GTD_BUSY = true

local function fetch(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" and #body > 500 then
        -- a captive portal / block page is html, the real script never is
        if not string.match(body, "^%s*<!DOCTYPE") and not string.match(body, "^%s*<html") then
            return body
        end
    end
    return nil
end

local function version_of(src)
    if type(src) ~= "string" then return nil end
    return src:match('version%s*=%s*"([%d%.]+)"') or src:match('VERSION%s*=%s*"([%d%.]+)"')
end

local function version_parts(v)
    local parts = {}
    for n in string.gmatch(tostring(v or ""), "%d+") do parts[#parts + 1] = tonumber(n) end
    return parts
end

local function is_newer(a, b)
    if not a then return false end
    if not b then return true end
    local pa, pb = version_parts(a), version_parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local has_files = (type(isfolder) == "function") and (type(makefolder) == "function")
    and (type(writefile) == "function") and (type(readfile) == "function")

local function read_cache()
    if not has_files then return nil end
    local ok, data = pcall(function() return readfile(CACHE_FILE) end)
    if ok and type(data) == "string" and #data > 500 then return data end
    return nil
end

-- raw github caches for minutes, jsDelivr for longer: try both, then pick whichever
-- is newest against what is already on disk.
local live = fetch(REPO .. "/Main.lua?v=" .. tostring(os.time()))
if not live then
    warn("[ANON GTD] raw github failed, trying jsDelivr mirror")
    live = fetch(MIRROR .. "/Main.lua")
end

local cached = read_cache()
local live_v, cached_v = version_of(live), version_of(cached)

local src, source_note
if live and cached and is_newer(cached_v, live_v) then
    src = cached
    source_note = string.format("github still serves v%s, kept newer cached v%s", tostring(live_v), tostring(cached_v))
else
    src = live or cached
    source_note = live and "github raw" or "disk cache"
end

env.__ANON_GTD_BUSY = nil

if not src then
    error("[ANON GTD] could not fetch Main.lua. check the repo path, the branch name, and that your executor has game:HttpGet", 0)
end

local chunk, compile_err = loadstring(src, "ANON_GTD_Main_" .. tostring(version_of(src) or "?"))
if not chunk and src == live and cached then
    -- live payload was truncated / mangled: fall back to the copy on disk
    warn("[ANON GTD] live payload broken, running the cached copy")
    chunk, compile_err = loadstring(cached, "ANON_GTD_Main_cached")
    src = cached
    source_note = "disk cache (live payload broken)"
end
if not chunk then
    error("[ANON GTD] compile error: " .. tostring(compile_err), 0)
end

if has_files and src == live then
    pcall(function()
        if not isfolder("ANON_GTD") then makefolder("ANON_GTD") end
        writefile(CACHE_FILE, src)
        writefile("ANON_GTD/version.txt", tostring(version_of(src) or VERSION))
    end)
end

warn(string.format("[ANON GTD] loader v%s · main v%s · source: %s", VERSION, tostring(version_of(src)), source_note))
return chunk()
