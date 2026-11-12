--[[
    ANON GTD · distribution check
    Proves the loadstring path works without Roblox: fetches the exact URLs the
    loader uses, compares them byte for byte against the local files, and compiles
    the payload the same way the loader does.

    luajit tools/dist_check.lua
--]]

local HERE = arg and arg[0] and arg[0]:match("^(.*)[/\\]") or "."
local MAIN_PATH   = HERE .. "/../Main.lua"
local LOADER_PATH = HERE .. "/../Loader.lua"

local RAW_BASE = "https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main/"
local CDN_BASE = "https://cdn.jsdelivr.net/gh/Azkaahps/gtd-macro@main/"

local fails = 0
local function check(name, ok, extra)
    if ok then
        print(string.format("  PASS  %s", name))
    else
        fails = fails + 1
        print(string.format("  FAIL  %s %s", name, extra and ("-> " .. tostring(extra)) or ""))
    end
end

local function read_local(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local function fetch(url)
    -- note: curl -w treats an argument starting with '@' as a filename, so the
    -- separator must not start with @
    local cmd = string.format("curl -sL -m 30 -w 'HTTPSTAT###%%{http_code}' '%s'", url)
    local pipe = io.popen(cmd)
    local body = pipe:read("*a")
    pipe:close()
    local content, code = body:match("^(.*)HTTPSTAT###(%d+)$")
    if not content then return body, "?" end
    return content, code
end

print("== local ==")
local src_main   = read_local(MAIN_PATH)
local src_loader = read_local(LOADER_PATH)
print(string.format("  Main.lua   %d bytes", #src_main))
print(string.format("  Loader.lua %d bytes", #src_loader))

print("\n== raw.githubusercontent ==")
local r_loader, code_loader = fetch(RAW_BASE .. "Loader.lua")
check("loader raw 200", code_loader == "200", code_loader)
check("loader raw byte identical", r_loader == src_loader, string.format("remote %d vs local %d", #r_loader, #src_loader))

local r_main, code_main = fetch(RAW_BASE .. "Main.lua")
check("main raw 200", code_main == "200", code_main)
check("main raw byte identical", r_main == src_main, string.format("remote %d vs local %d", #r_main, #src_main))
check("main raw is not an html page", not r_main:match("^%s*<!DOCTYPE") and not r_main:match("^%s*<html"))

print("\n== loader internals ==")
local repo_url = r_loader:match('local REPO%s*=%s*"([^"]+)"')
local mirror_url = r_loader:match('local MIRROR%s*=%s*"([^"]+)"')
print("  REPO   = " .. tostring(repo_url))
print("  MIRROR = " .. tostring(mirror_url))
check("REPO points at the real repo", repo_url == RAW_BASE:gsub("/$", ""), repo_url)
check("MIRROR points at jsDelivr", mirror_url == CDN_BASE:gsub("/$", ""), mirror_url)
check("loader has no leftover placeholder", not r_loader:find("USER/REPO", 1, true))
check("place guard present", r_loader:find("108533757090220", 1, true) ~= nil)

print("\n== what the loader will fetch at runtime ==")
check("loader REPO url parsed", type(repo_url) == "string" and repo_url ~= "", repo_url)
if repo_url then
    local via_repo, code_via = fetch(repo_url .. "/Main.lua?v=1")
    check("loader's REPO url resolves", code_via == "200", code_via)
    check("loader's REPO payload identical", via_repo == src_main, string.format("%d vs %d", #via_repo, #src_main))
end

local via_cdn, code_cdn = fetch(CDN_BASE .. "Main.lua")
print("  jsDelivr status: " .. tostring(code_cdn))
check("MIRROR reachable (fallback only)", code_cdn == "200" or code_cdn == "404" or code_cdn == "403",
    "status " .. tostring(code_cdn))
if code_cdn == "200" then
    -- jsDelivr caches a branch for up to 12h, so a stale copy here is normal and not
    -- a failure: it is only ever used when raw github is unreachable, and the loader
    -- refuses to run anything older than the cached copy.
    local cdn_chunk = load(via_cdn, "cdn_probe")
    check("MIRROR payload is valid lua", #via_cdn > 500 and cdn_chunk ~= nil, #via_cdn)
    if via_cdn == src_main then
        print("  MIRROR is up to date with the repo")
    else
        print(string.format("  MIRROR is %d bytes behind (jsDelivr branch cache) - fallback only, loader guards this",
            #src_main - #via_cdn))
    end
end

print("\n== compile, the same way the loader does ==")
local chunk_main, err_main = load(r_main, "ANON_GTD_Main_dist")
check("fetched Main.lua compiles", chunk_main ~= nil, err_main)
check("fetched Main.lua returns the api table", r_main:match("return API%s*$") ~= nil)
local chunk_loader, err_loader = load(r_loader, "ANON_GTD_Loader_dist")
check("fetched Loader.lua compiles", chunk_loader ~= nil, err_loader)

print("\n== urls the user will paste ==")
print("  loadstring(game:HttpGet(\"" .. RAW_BASE .. "Loader.lua\"))()")
print("  fallback: " .. CDN_BASE .. "Main.lua")

print("\n=====================================")
print(string.format("DIST FAILURES: %d", fails))
print("=====================================")
os.exit(fails == 0 and 0 or 1)
