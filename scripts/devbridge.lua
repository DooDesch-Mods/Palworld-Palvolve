-- devbridge.lua: run Lua inside PALVOLVE'S OWN Lua state from outside the game.
--
-- Why this exists. UE4SS gives every mod its own lua_State, so the ue4ss-bridge
-- mod cannot `require("evolution")` or touch anything Palvolve holds - from
-- there Palvolve is just another process's memory. That gap meant the paths
-- that live behind the mod's own modules could only be exercised by a human at
-- the keyboard: the evolve wheel, the bonus slot report, the chat replies. Four
-- of them went into a test plan for exactly that reason, which is three too
-- many.
--
-- ModRef:SetSharedVariable is the one channel that crosses states. It carries
-- strings, numbers and booleans, so the wire is a string: a sequence number, a
-- separator, and a payload. The caller writes a request, this poller runs it
-- here and writes the answer back.
--
-- TWO GATES, both of which must hold:
--   1. Config.devMode is true. It ships false and is a dev switch.
--   2. deploy-mod.ps1 put this copy here, proven by the marker file it writes
--      beside the mod. A Workshop copy, a release zip or a manual install has
--      no marker, so this cannot arm there even with devMode on by accident.
--
-- It is loaded from main.lua next to the probes, under the same devMode branch.

local Config = require("config")

local DevBridge = {}

local MOD_NAME = "Palvolve"
local REQ_VAR = "palvolve_dev_req"
local RES_VAR = "palvolve_dev_res"
local POLL_MS = 200
local SEP = "\1"
local MAX_RESULT_BYTES = 96 * 1024

local function Log(msg)
    print(string.format("[%s] [devbridge] %s\n", MOD_NAME, tostring(msg)))
end

-- ---------------------------------------------------------------- the gates

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

--- true only where deploy-mod.ps1 put this mod, false everywhere else.
---
--- The proof is a marker file the deploy script writes next to the scripts
--- folder. Walking up for Workspace/config/local.json only works for the test
--- client, which lives inside the workspace; the dedicated test server sits in
--- a Steam library on another drive and never finds it. A marker covers both
--- and needs no path rules at all.
---
--- The marker exists nowhere but where the deploy wrote it. A copy from the
--- Workshop, a release zip or a manual install has none, so this cannot arm
--- there even with devMode switched on by accident.
---
--- Deliberately fails closed: anything it cannot prove counts as "not a dev
--- install".
local function isDevInstall()
    local source = ""
    pcall(function() source = debug.getinfo(1, "S").source or "" end)
    local path = tostring(source):gsub("^@", "")
    if path == "" then return false, "this loader does not say where the mod was loaded from" end

    -- .../Mods/Palvolve/scripts/devbridge.lua -> .../Mods/Palvolve/
    local modDir = path:gsub("[^/\\]+$", ""):gsub("[Ss]cripts[/\\]$", "")
    local marker = readFile(modDir .. ".workspace-devinstall")
    if not marker then return false, "no .workspace-devinstall marker beside the mod" end
    local label = tostring(marker):match("^%s*([^\r\n]*)") or ""
    return true, label ~= "" and label or "dev install"
end

-- ------------------------------------------------------------ serialisation

local function encode(value, depth)
    depth = depth or 0
    local t = type(value)
    if value == nil then return "nil" end
    if t == "number" or t == "boolean" then return tostring(value) end
    if t == "string" then return string.format("%q", value) end
    if t ~= "table" then return string.format("%q", "<" .. t .. ">") end
    if depth >= 4 then return '"<deep>"' end

    local parts = {}
    local n = 0
    -- array first, so a list of options comes back as a list
    local isArray = #value > 0
    if isArray then
        for i = 1, #value do
            n = n + 1
            if n > 200 then parts[#parts + 1] = '"<truncated>"' break end
            parts[#parts + 1] = encode(value[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, v in pairs(value) do
        n = n + 1
        if n > 200 then parts[#parts + 1] = '"<truncated>": true' break end
        parts[#parts + 1] = string.format("%q", tostring(k)) .. ":" .. encode(v, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ------------------------------------------------------------------ the loop

local lastSeq = nil

local function respond(seq, status, payload)
    local body = tostring(payload)
    if #body > MAX_RESULT_BYTES then
        body = body:sub(1, MAX_RESULT_BYTES) .. "...<truncated>"
    end
    local ok, err = pcall(function()
        ModRef:SetSharedVariable(RES_VAR, seq .. SEP .. status .. SEP .. body)
    end)
    if not ok then
        -- The answer is the whole point, so a failure to hand it back is not
        -- allowed to be quiet.
        Log("could not write the response: " .. tostring(err))
    end
end

local function serve()
    local req = nil
    local okRead = pcall(function() req = ModRef:GetSharedVariable(REQ_VAR) end)
    if not okRead or type(req) ~= "string" or req == "" then return end

    local seq, code = req:match("^([^" .. SEP .. "]+)" .. SEP .. "(.*)$")
    if not seq or seq == lastSeq then return end
    lastSeq = seq

    local chunk, loadErr = load(code, "palvolve-dev-request", "t")
    if not chunk then
        respond(seq, "err", "does not compile: " .. tostring(loadErr))
        return
    end
    local okRun, result = pcall(chunk)
    if not okRun then
        respond(seq, "err", tostring(result))
        return
    end
    local okEnc, encoded = pcall(encode, result)
    respond(seq, "ok", okEnc and encoded or ('"<result could not be encoded>"'))
end

function DevBridge.init()
    if not Config.devMode then return end
    local allowed, why = isDevInstall()
    if not allowed then
        Log("not armed: " .. tostring(why))
        return
    end
    if type(ModRef) ~= "userdata" then
        Log("not armed: this UE4SS build exposes no ModRef")
        return
    end
    pcall(function() ModRef:SetSharedVariable(RES_VAR, "") end)
    LoopAsync(POLL_MS, function()
        pcall(serve)
        return false
    end)
    Log("armed on the " .. tostring(why) .. ": running requests from " .. REQ_VAR .. " in Palvolve's own Lua state")
end

return DevBridge
