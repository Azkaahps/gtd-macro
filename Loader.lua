--[[
================================================================================
  ANON · Garden Tower Defense — loader  (v1.0.0)
  Paste this one line in Delta / any executor:

      loadstring(game:HttpGet("<raw url of this file>"))()

  It pulls Main.lua from GitHub raw (jsDelivr mirror as fallback), caches it to
  the executor folder so a re-run survives a GitHub hiccup, then executes it.
  ------------------------------------------------------------------- setup
  1. push Main.lua to a PUBLIC repo, remember user/repo and the branch (main)
  2. edit REPO / MIRROR below to match
  3. bump VERSION every time you push a new Main.lua
================================================================================
--]]

local VERSION = "1.0.0"
local REPO    = "https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main"
local MIRROR  = "https://cdn.jsdelivr.net/gh/Azkaahps/gtd-macro@main"

local PLACES = {
    [108533757090220] = "Garden Tower Defense",
    [123516946198836] = "Garden Tower Defense (2)",
}

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

-- raw.githubusercontent is cached ~5 minutes, the query breaks that cache
local src = fetch(REPO .. "/Main.lua?v=" .. tostring(os.time()))
if not src then
    warn("[ANON GTD] raw github failed, trying jsDelivr mirror")
    src = fetch(MIRROR .. "/Main.lua")
end
env.__ANON_GTD_BUSY = nil

if not src then
    error("[ANON GTD] could not fetch Main.lua. check the repo path, the branch name, and that your executor has game:HttpGet", 0)
end

-- cache so the next run can fall back to disk when GitHub is unreachable
local has_files = (type(isfolder) == "function") and (type(makefolder) == "function")
    and (type(writefile) == "function") and (type(readfile) == "function")

if has_files then
    pcall(function()
        if not isfolder("ANON_GTD") then makefolder("ANON_GTD") end
        writefile("ANON_GTD/Main.lua", src)
        writefile("ANON_GTD/version.txt", VERSION)
    end)
end

local chunk, compile_err = loadstring(src, "ANON_GTD_Main_" .. VERSION)
if not chunk then
    -- network answered but the payload was not valid lua (proxy page, truncated file)
    if has_files then
        local ok, cached = pcall(function() return readfile("ANON_GTD/Main.lua") end)
        if ok and cached and #cached > 500 then
            local c2 = loadstring(cached, "ANON_GTD_Main_cached")
            if c2 then
                warn("[ANON GTD] live payload broken, running the cached copy")
                return c2()
            end
        end
    end
    error("[ANON GTD] compile error: " .. tostring(compile_err), 0)
end

return chunk()
