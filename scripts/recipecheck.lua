-- recipecheck.lua: names a recipe material the world does not have.
--
-- The bench shows a recipe only if every id in it resolves. One material the
-- game does not know drops that single row, and nothing anywhere says so: the
-- product item is still registered and still logged, so from the outside a
-- healthy install and a broken recipe look identical. A reporter arrived with
-- exactly that - the Evolution Stone gone from the Pal Alchemy Workbench while
-- every other Palvolve recipe was on it, and the log showing the stone as
-- added. His copy of DT_ItemRecipeDataTable.json named a material that exists
-- in no version of this mod and in no table of the game.
--
-- So the recipes this mod ships are read back and every id in them is asked
-- for. Whatever does not answer is named, with the row it sits in, which turns
-- a support thread into a line the reader can act on.
--
-- Runs once, off the back of the bench filter's install check, which already
-- waits for the item manager. Quiet when everything resolves.

local RecipeCheck = {}

local MOD_NAME = "Palvolve"
local FILES = { "DT_ItemRecipeDataTable.json", "DT_ItemRecipeDataTable_Prestige.json" }

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

-- <...>/Mods/Palvolve/scripts/recipecheck.lua -> <...>/Mods/PalSchema/mods/Palvolve/raw/
-- Same walk as prestigerecipe.lua, which writes into that folder.
local function rawDir()
    local dir = nil
    pcall(function()
        local src = debug.getinfo(1, "S").source
        if src:sub(1, 1) ~= "@" then return end
        local scripts = src:sub(2):match("^(.*)[/\\]")           -- .../Palvolve/scripts
        local modRoot = scripts and scripts:match("^(.*)[/\\]")  -- .../Palvolve
        local modsDir = modRoot and modRoot:match("^(.*)[/\\]")  -- .../Mods
        if modsDir then
            dir = modsDir .. "\\PalSchema\\mods\\Palvolve\\raw\\"
        end
    end)
    return dir
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

--- Every id the file names, as { id = "row name" }.
---
--- Deliberately a scan rather than a JSON parse: the shape is fixed and written
--- by this project, and a parser here would be a second thing that can be wrong
--- about a file whose only job is to be read by PalSchema.
local function idsIn(body)
    local found = {}
    local row = "?"
    for line in body:gmatch("[^\r\n]+") do
        local name = line:match('^%s*"([%w_]+)"%s*:%s*{')
        if name then row = name end
        local key, id = line:match('"(%a[%w_]*_Id)"%s*:%s*"([^"]+)"')
        if key and id and id ~= "None" then
            -- first row wins: the same material in two recipes is one problem,
            -- and naming the first one is enough to find it
            if not found[id] then found[id] = row end
        end
    end
    return found
end

--- Runs the check. Call only once the item manager is up and Palvolve's own
--- data is known to be applied - a world without any of it is a different
--- fault, and the bench filter already says so in full.
function RecipeCheck.run()
    local dir = rawDir()
    if not dir then
        Log("[WARN] recipe check: could not resolve the PalSchema raw folder - recipes unchecked")
        return
    end

    local mgr = nil
    pcall(function() mgr = FindFirstOf("PalItemIDManager") end)
    if not (mgr and mgr:IsValid()) then
        Log("[WARN] recipe check: no item manager - recipes unchecked")
        return
    end

    local checked, missing, unreadable = 0, 0, 0
    for _, file in ipairs(FILES) do
        local body = readFile(dir .. file)
        if not body then
            unreadable = unreadable + 1
            Log(string.format("[WARN] recipe check: %s is not readable, so its recipes are unchecked", file))
        else
            for id, row in pairs(idsIn(body)) do
                checked = checked + 1
                local ok = false
                pcall(function()
                    local data = mgr:GetStaticItemData(FName(id))
                    ok = data ~= nil and data:IsValid()
                end)
                if not ok then
                    missing = missing + 1
                    Log(string.format(
                        "the item '%s' does not exist in this world, so the recipe '%s' in %s is "
                        .. "dropped and never reaches the Pal Alchemy Workbench. Everything else "
                        .. "still works. If you edited that file, put the id back; if you did not, "
                        .. "a leftover copy of Palvolve's PalSchema folder is being loaded instead "
                        .. "of the current one - delete it from Mods\\ManagedMods and from "
                        .. "ue4ss\\Mods, then subscribe again.",
                        id, row, file))
                end
            end
        end
    end

    -- A clean run is invisible on purpose, but the operator gets one line, so
    -- "every recipe resolved" and "the check never ran" stay distinguishable.
    if missing == 0 and unreadable == 0 then
        local Config = require("config")
        if Config.devMode then
            Log(string.format("[INFO] recipe check: %d item id(s) resolved", checked))
        end
    end
end

return RecipeCheck
