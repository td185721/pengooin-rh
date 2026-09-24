-- Robust loader for RoyalHighDiamondFarm.lua
-- Tries every common http + loadstring shape so it survives all major
-- executors (Synapse X, Fluxus, KRNL, Wave, Codex, Delta, Xeno, etc.).

local URL = "https://raw.githubusercontent.com/td185721/pengooin-rh/main/RoyalHighDiamondFarm.lua?t=" .. tostring(tick())

local function fetch(url)
    -- Try each HTTP entry point in the order most executors expose them.
    local ok, body

    ok, body = pcall(function() return game:HttpGet(url) end)
    if ok and type(body) == "string" and #body > 100 then return body end

    ok, body = pcall(function() return game:HttpGetAsync(url) end)
    if ok and type(body) == "string" and #body > 100 then return body end

    ok, body = pcall(function()
        local HttpService = game:GetService("HttpService")
        return HttpService:GetAsync(url)
    end)
    if ok and type(body) == "string" and #body > 100 then return body end

    -- syn.request / http.request / request — executor-specific
    for _, fn in ipairs({
        rawget(getfenv(), "request"),
        rawget(getfenv(), "http_request"),
        (syn and syn.request),
        (http and http.request),
        (fluxus and fluxus.request),
    }) do
        if type(fn) == "function" then
            ok, body = pcall(fn, { Url = url, Method = "GET" })
            if ok and type(body) == "table" and type(body.Body) == "string" and #body.Body > 100 then
                return body.Body
            end
        end
    end

    return nil
end

local function compile(source)
    -- Locate a loadstring-shaped function even if the executor renamed it.
    local ls =
           rawget(getfenv(), "loadstring")
        or (getgenv and getgenv().loadstring)
        or rawget(getfenv(), "LoadString")
        or rawget(getfenv(), "load")
    if type(ls) ~= "function" then
        error("no loadstring / load function exposed by this executor", 0)
    end
    local fn, err = ls(source, "RoyalHighDiamondFarm")
    if not fn then error("compile failed: " .. tostring(err), 0) end
    return fn
end

local source = fetch(URL)
if not source then
    error("failed to fetch " .. URL .. " — check executor http permissions", 0)
end
compile(source)()
