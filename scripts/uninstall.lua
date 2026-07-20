-- uninstall.lua: clean-removal helpers for the mod's persistent traces.
--
-- Saves store items as FName references (PalItemId.StaticId) into the item
-- DataTable. Once the PalSchema half is uninstalled those rows are gone, the
-- references stop resolving and the world crashes on load - and PalSchema's
-- own invalid-item cleanup is broken on this game build (its native signature
-- for UPalItemSlot::UpdateItem_ServerInternal is not found, logged at every
-- startup). So the mod has to offer its own way out while it is still
-- installed: delete its items for real (discard only drops them, and ground
-- drops persist), and neutralize the technology unlock FName.
local Costs = require("costs")

local Uninstall = {}

-- Every item id the PalSchema half defines. Only the evolution/adaptation
-- stones are referenced elsewhere in Lua (config.stoneItemIds); the essences
-- exist purely in recipes, so the full list lives here.
local ELEMENTS = { "Normal", "Fire", "Water", "Leaf", "Electricity", "Ice", "Earth", "Dark", "Dragon" }
local ITEM_IDS = {
    "Palvolve_EvolutionStone",
    "Palvolve_AdaptionStone", -- legacy generic stone (historic spelling)
}
for _, e in ipairs(ELEMENTS) do
    table.insert(ITEM_IDS, "Palvolve_AdaptationStone_" .. e)
    table.insert(ITEM_IDS, "Palvolve_Essence_" .. e)
end

local TECH_NAME = "Palvolve_ElementExtractor"

-- ------------------------------------------------------------------- items

-- Counts every mod item still in the player's inventory. The report is the
-- honest half of the story: chests, ground drops, work queues and offline
-- players are out of reach from Lua (their container APIs expose no removal),
-- so the caller must say so instead of implying the world is clean.
function Uninstall.countReport(playerCtx)
    local found, total = {}, 0
    for _, id in ipairs(ITEM_IDS) do
        local n = Costs.countItem(playerCtx, id)
        if n > 0 then
            table.insert(found, string.format("%dx %s", n, id))
            total = total + n
        end
    end
    return total, found
end

-- Removes every mod item from the player's inventory (real deletion, not a
-- drop). Returns what was removed and which ids failed the count-verified
-- consume.
function Uninstall.sweepInventory(playerCtx)
    local removed, failed = {}, {}
    for _, id in ipairs(ITEM_IDS) do
        local have = Costs.countItem(playerCtx, id)
        if have > 0 then
            if Costs.removeAll(playerCtx, id, have) then
                table.insert(removed, string.format("%dx %s", have, id))
            else
                table.insert(failed, id)
            end
        end
    end
    return removed, failed
end

-- -------------------------------------------------------------------- tech

-- The unlocked-technology list is a replicated TArray<FName>
-- (PalTechnologyData.UnlockedTechnologyNameArray); the persisted copy is
-- PalWorldPlayerSaveData.UnlockedRecipeTechnologyNames. Membership is checked
-- by existence scans and there is no reflected function to re-lock an entry.
-- Removal therefore works by OVERWRITING our FName in place with a duplicate
-- of another element from the same array: the length never changes (resizing
-- a native TArray from Lua corrupts it), duplicates do not change any
-- membership answer, and the dangling mod reference is gone.

-- Array elements may come back as RemoteUnrealParam wrappers; unwrap first.
local function nameAt(arr, i)
    local v = arr[i]
    if type(v) == "userdata" then
        pcall(function()
            local inner = v.get and v:get() or nil
            if inner ~= nil then v = inner end
        end)
    end
    local s = ""
    pcall(function() s = v:ToString() end)
    return s
end

-- An earned unlock lives in TWO places: the runtime
-- PalTechnologyData.UnlockedTechnologyNameArray (outer is the
-- PalPlayerAccount; stable, always in memory, and what the game's own
-- IsUnlockRecipeTechnology answers from) and the persisted
-- PalWorldPlayerSaveGame.SaveData.UnlockedRecipeTechnologyNames - whose
-- object is TRANSIENT and only sometimes reachable. Neutralization therefore
-- writes every array it can find: the runtime one carries the truth into the
-- next save, the save-game one is cleaned opportunistically when present.
local function techArrays()
    local arrays = {}
    pcall(function()
        local tds = FindAllOf("PalTechnologyData") or {}
        for _, td in ipairs(tds) do
            if td:IsValid() then
                local arr = nil
                pcall(function() arr = td.UnlockedTechnologyNameArray end)
                if arr then table.insert(arrays, arr) end
            end
        end
    end)
    pcall(function()
        local saves = FindAllOf("PalWorldPlayerSaveGame") or {}
        for _, sg in ipairs(saves) do
            if sg:IsValid() then
                local arr = nil
                pcall(function() arr = sg.SaveData.UnlockedRecipeTechnologyNames end)
                if arr then table.insert(arrays, arr) end
            end
        end
    end)
    return arrays
end

-- Wide diagnosis pass: every PalTechnologyData instance in memory, its array
-- length, whether it lists the mod tech, and what the game's own membership
-- check answers. This settles WHERE an earned unlock actually lives.
function Uninstall.techDiag()
    local lines = {}
    pcall(function()
        local all = FindAllOf("PalTechnologyData") or {}
        table.insert(lines, string.format("PalTechnologyData instances: %d", #all))
        for k, td in ipairs(all) do
            if td:IsValid() then
                local n, has, isUnlocked = 0, false, "?"
                pcall(function() n = #td.UnlockedTechnologyNameArray end)
                pcall(function()
                    for i = 1, n do
                        if nameAt(td.UnlockedTechnologyNameArray, i) == TECH_NAME then has = true end
                    end
                end)
                pcall(function() isUnlocked = tostring(td:IsUnlockRecipeTechnology(FName(TECH_NAME))) end)
                local outer = "?"
                pcall(function() outer = td:GetOuter():GetFName():ToString() end)
                table.insert(lines, string.format("td%d outer=%s len=%d listsOurs=%s IsUnlock=%s",
                    k, outer, n, tostring(has), isUnlocked))
            end
        end
    end)
    for _, l in ipairs(lines) do print("[Palvolve] [xtech] " .. l .. "\n") end
    return table.concat(lines, " | ")
end

function Uninstall.techInspect(playerCtx)
    local arrays = techArrays()
    if #arrays == 0 then return "no player save objects reachable; " .. Uninstall.techDiag() end
    local report = {}
    for a, arr in ipairs(arrays) do
        local n = #arr
        local elemType = "?"
        pcall(function() elemType = type(arr[1]) end)
        local idx, donor = nil, nil
        for i = 1, n do
            local s = nameAt(arr, i)
            -- full dump to the log: the raw contents show whether this is the
            -- right array when the mod's tech is reported absent
            print(string.format("[Palvolve] [xtech] save%d %d/%d = '%s'\n", a, i, n, s))
            if s == TECH_NAME then
                idx = i
            elseif not donor and s ~= "" and s ~= "None" and not s:find("^Palvolve_") then
                donor = i
            end
        end
        table.insert(report, string.format("save%d: len=%d elemType=%s ourIdx=%s donorIdx=%s",
            a, n, elemType, tostring(idx), tostring(donor)))
    end
    return table.concat(report, " | ")
end

-- The in-place replace. Never resizes; verifies by reading back. Returns a
-- human-readable result line; "OK" only when the readback no longer shows the
-- mod's tech name.
function Uninstall.techNeutralize(playerCtx)
    local arrays = techArrays()
    if #arrays == 0 then return false, "no player save objects reachable" end
    local cleaned, present, failed = 0, 0, nil
    for _, arr in ipairs(arrays) do
        local n = #arr
        local idx, donor = nil, nil
        for i = 1, n do
            local s = nameAt(arr, i)
            if s == TECH_NAME then
                idx = i
            elseif not donor and s ~= "" and s ~= "None" and not s:find("^Palvolve_") then
                donor = i
            end
        end
        if idx then
            present = present + 1
            if not donor then
                failed = "no donor element found - nothing written"
            else
                local donorName = nameAt(arr, donor)
                local wrote = pcall(function() arr[idx] = FName(donorName) end)
                local back = wrote and nameAt(arr, idx) or TECH_NAME
                if back ~= TECH_NAME then
                    cleaned = cleaned + 1
                else
                    failed = "element write had no effect"
                end
            end
        end
    end
    if present == 0 then
        return true, string.format("'%s' not unlocked by any present player - nothing to do", TECH_NAME)
    end
    if failed then
        return false, failed
    end
    return true, string.format("removed from %d player save(s) (readback OK)", cleaned)
end

-- -------------------------------------------------------------- world scan

-- Container APIs expose no removal, but they are fully readable - so instead
-- of asking players to search every chest by hand (base pals silently haul
-- discarded stacks into storage), the scan tells them exactly where leftovers
-- sit. Read-only by construction: Get/Num/Find only.

local function palUtility()
    local u = StaticFindObject("/Script/Pal.Default__PalUtility")
    if u and u:IsValid() then return u end
    return nil
end

local function guidsEqual(a, b)
    local eq = false
    pcall(function() eq = (a.A == b.A and a.B == b.B and a.C == b.C and a.D == b.D) end)
    return eq
end

-- The player's own six inventory container ids (main, drop, essential,
-- weapon loadout, armor, food) - matched so the report can label "your own
-- inventory" instead of listing it as an unknown location.
local function playerContainerIds(playerCtx)
    local ids = {}
    pcall(function()
        local ps = playerCtx.pc:GetPalPlayerState()
        local info = ps:GetInventoryData().MyInventoryInfo
        for _, key in ipairs({ "CommonContainerId", "DropSlotContainerId", "EssentialContainerId",
                               "WeaponLoadOutContainerId", "PlayerEquipArmorContainerId",
                               "FoodEquipContainerId" }) do
            pcall(function() table.insert(ids, info[key].ID) end)
        end
    end)
    return ids
end

local function describeOwner(mgr, bcm, ownerGuid)
    local label = nil
    pcall(function()
        local model = mgr:FindModel(ownerGuid)
        if not (model and model:IsValid()) then
            print(string.format("[Palvolve] [scan] owner lookup failed (guid %08X-%08X-%08X-%08X, mgr %s)\n",
                ownerGuid and ownerGuid.A or 0, ownerGuid and ownerGuid.B or 0,
                ownerGuid and ownerGuid.C or 0, ownerGuid and ownerGuid.D or 0,
                tostring(mgr ~= nil)))
            return
        end
        local objName = ""
        pcall(function() objName = model.MapObjectMasterDataId:ToString() end)
        local custom = ""
        pcall(function() custom = model.CustomName end)
        if custom ~= "" then objName = objName .. " '" .. custom .. "'" end
        local pos = ""
        pcall(function()
            local t = model.InitialTransformCache.Translation
            pos = string.format(" near world (%d, %d)", math.floor(t.X / 100), math.floor(t.Y / 100))
        end)
        local base = ""
        pcall(function()
            local campOut = {}
            if bcm and bcm:TryGetModel(model.BaseCampIdBelongTo, campOut) and campOut.Model then
                local nameStr = campOut.Model.BaseCampName
                if nameStr and nameStr ~= "" then base = " at base '" .. nameStr .. "'" end
            end
        end)
        label = objName .. base .. pos
    end)
    return label
end

-- Scans every item container in the world for mod items. Returns:
--   locations - human-readable lines for stacks OUTSIDE the caller's inventory
--   ownInventory - total count sitting in the caller's own inventory
function Uninstall.worldScan(playerCtx)
    local locations, ownInventory, orphans = {}, 0, {}
    local scanOk, scanErr = pcall(function()
        local containers = FindAllOf("PalItemContainer") or {}
        print(string.format("[Palvolve] [scan] containers=%d\n", #containers))
        local util = palUtility()
        -- manager resolution mirrors evolution.lua's findManager: an in-world
        -- actor as the context first, then the live instance directly. A bare
        -- World object as context yields nil managers.
        local mgr, bcm = nil, nil
        pcall(function()
            local pc = playerCtx and playerCtx.pc
            if util and pc and pc:IsValid() then
                mgr = util:GetMapObjectManager(pc)
                bcm = util:GetBaseCampManager(pc)
            end
        end)
        if not (mgr and mgr:IsValid()) then
            pcall(function() mgr = FindFirstOf("PalMapObjectManager") end)
        end
        if not (bcm and bcm:IsValid()) then
            pcall(function() bcm = FindFirstOf("PalBaseCampManager") end)
        end
        print(string.format("[Palvolve] [scan] mgr=%s bcm=%s\n",
            tostring(mgr and mgr:IsValid()), tostring(bcm and bcm:IsValid())))
        local ownIds = playerContainerIds(playerCtx)
        for _, c in ipairs(containers) do
            if c:IsValid() then
                local hits = {}
                pcall(function()
                    local n = c:Num()
                    for i = 0, n - 1 do
                        local slot = c:Get(i)
                        if slot and slot:IsValid() and not slot:IsEmpty() then
                            local sid = ""
                            pcall(function() sid = slot:GetItemId().StaticId:ToString() end)
                            if sid:find("^Palvolve_") then
                                local count = 0
                                pcall(function() count = slot:GetStackCount() end)
                                table.insert(hits, string.format("%dx %s", count, sid))
                            end
                        end
                    end
                end)
                if #hits > 0 then
                    -- classify: the caller's own inventory is handled by the
                    -- sweep, everything else needs the player to walk there
                    local isOwn = false
                    pcall(function()
                        local slot0 = c:Get(0)
                        if slot0 and slot0:IsValid() then
                            local cid = slot0.ContainerId.ID
                            for _, oid in ipairs(ownIds) do
                                if guidsEqual(cid, oid) then isOwn = true break end
                            end
                        end
                    end)
                    if isOwn then
                        for _, h in ipairs(hits) do
                            local n = tonumber(h:match("^(%d+)x")) or 0
                            ownInventory = ownInventory + n
                        end
                    else
                        local where = nil
                        pcall(function()
                            if mgr then where = describeOwner(mgr, bcm, c.OwnerMapObjectInstanceId) end
                        end)
                        local isOrphan = false
                        if not where then
                            -- no live map object owns this container: either a
                            -- pal carries it, or it is ORPHANED (its chest was
                            -- destroyed while the container survived in the
                            -- save). Try the pal route before labeling it.
                            pcall(function()
                                local cid = nil
                                local slot0 = c:Get(0)
                                if slot0 and slot0:IsValid() then cid = slot0.ContainerId.ID end
                                if not cid then return end
                                local params = FindAllOf("PalIndividualCharacterParameter") or {}
                                for _, p in ipairs(params) do
                                    if p:IsValid() then
                                        local pid = nil
                                        pcall(function() pid = p:GetEquipItemContainerId().ID end)
                                        if pid and guidsEqual(cid, pid) then
                                            local nick = "?"
                                            pcall(function() nick = p:GetNickName() end)
                                            pcall(function()
                                                if nick == "" or nick == "?" then
                                                    nick = p:GetCharacterID():ToString()
                                                end
                                            end)
                                            where = "carried by pal '" .. tostring(nick) .. "'"
                                            return
                                        end
                                    end
                                end
                                where = "an ORPHANED container (its chest no longer exists; " ..
                                    "these items cannot be collected by hand)"
                                isOrphan = true
                            end)
                        end
                        if isOrphan then table.insert(orphans, c) end
                        table.insert(locations, table.concat(hits, ", ") .. " in " ..
                            (where or "a pal's or another player's inventory"))
                    end
                end
            end
        end
    end)
    if not scanOk then
        print("[Palvolve] [scan] ERROR " .. tostring(scanErr) .. "\n")
    end
    print(string.format("[Palvolve] [scan] done: %d foreign locations (%d orphaned), %d in own inventory\n",
        #locations, #orphans, ownInventory))
    return locations, ownInventory, orphans
end

-- RETIRED from the shipping path, kept for devMode research only. Rewriting
-- slot ItemIds in orphaned containers looked like the same in-place FName
-- technique the tech neutralization proved - but a world saved after this
-- write crashed natively on the next load, matching the warned-about class of
-- nested-struct item mutations. Do NOT wire this into the uninstall command
-- again without an offline save-diff proving the write is byte-clean.
function Uninstall.convertOrphans(orphans)
    local converted, failed = 0, 0
    for _, c in ipairs(orphans) do
        pcall(function()
            local n = c:Num()
            for i = 0, n - 1 do
                local slot = c:Get(i)
                if slot and slot:IsValid() and not slot:IsEmpty() then
                    local sid = ""
                    pcall(function() sid = slot:GetItemId().StaticId:ToString() end)
                    if sid:find("^Palvolve_") then
                        local wrote = pcall(function() slot.ItemId.StaticId = FName("Stone") end)
                        local back = ""
                        pcall(function() back = slot:GetItemId().StaticId:ToString() end)
                        if wrote and back == "Stone" then
                            converted = converted + 1
                        else
                            failed = failed + 1
                            print(string.format("[Palvolve] [orphan] convert failed slot %d ('%s' readback '%s')\n",
                                i, sid, back))
                        end
                    end
                end
            end
        end)
    end
    print(string.format("[Palvolve] [orphan] converted=%d failed=%d\n", converted, failed))
    return converted, failed
end

-- Every placed Pal Alchemy Workbench, with a position hint. Two passes: the
-- actor route is the idiom benchvisual.lua already uses
-- (PalBuildObject.BuildObjectId carries the PalSchema id even though the bench
-- reuses the vanilla medicine-facility blueprint); the model route is kept as
-- a net for benches whose actor is not streamed in. Matching on
-- MapObjectMasterDataId alone finds neither.
function Uninstall.findBenches()
    local found, seen = {}, {}
    pcall(function()
        local actors = FindAllOf("PalBuildObject") or {}
        for _, a in ipairs(actors) do
            if a:IsValid() then
                local bid = ""
                pcall(function() bid = a.BuildObjectId:ToString() end)
                if bid == "Palvolve_ElementExtractor" then
                    local pos = "somewhere"
                    pcall(function()
                        local loc = a:K2_GetActorLocation()
                        pos = string.format("world (%d, %d)", math.floor(loc.X / 100), math.floor(loc.Y / 100))
                    end)
                    table.insert(found, pos)
                    seen[pos] = true
                end
            end
        end
    end)
    pcall(function()
        local models = FindAllOf("PalMapObjectModel") or {}
        for _, m in ipairs(models) do
            if m:IsValid() then
                local id, bid = "", ""
                pcall(function() id = m.MapObjectMasterDataId:ToString() end)
                pcall(function() bid = m.BuildObjectId:ToString() end)
                if id == "Palvolve_ElementExtractor" or bid == "Palvolve_ElementExtractor" then
                    local pos = "somewhere"
                    pcall(function()
                        local t = m.InitialTransformCache.Translation
                        pos = string.format("world (%d, %d)", math.floor(t.X / 100), math.floor(t.Y / 100))
                    end)
                    if not seen[pos] then table.insert(found, pos) end
                end
            end
        end
    end)
    print(string.format("[Palvolve] [scan] benches found=%d\n", #found))
    return found
end

Uninstall.ITEM_IDS = ITEM_IDS
Uninstall.TECH_NAME = TECH_NAME

return Uninstall
