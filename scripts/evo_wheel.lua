-- Palvolve wheel entries: the evolution and fusion options a Pal offers, with the
-- requirement text shown in the wheel's centre.

local Conditions = require("conditions")
local Config = require("config")
local Costs = require("costs")
local I18n = require("i18n")
local Ride = require("ride")
local Role = require("role")
local ServerCheck = require("servercheck")
local EvoUtil = require("evo_util")
local EvoNames = require("evo_names")
local EvoState = require("evo_state")
local EvoLock = require("evo_lock")

local EvoWheel = {}

local MOD_NAME = "Palvolve"
local function Log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

-- Fusion entries for the wheel: one per party partner of the summoned Pal. The
-- altar is not in the wheel: its window opens when the second Pal is set into
-- it (altar.lua), the way Pals go into a display cage.
local function fusionOptions(playerCtx)
    local out = {}
    if not (Config.fusion and Config.fusion.enabled and playerCtx) then return out end
    local Fusion = package.loaded["fusion"]
    if Fusion then
        local holder = EvoUtil.findHolderFor(playerCtx, nil)
        local actor = nil
        if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
        local param = actor and actor:IsValid() and EvoUtil.paramOf(actor) or nil
        if param and EvoUtil.isOwnedBy(param, playerCtx.playerUId) then
            local ok, list = pcall(Fusion.wheelOptions, playerCtx, holder, param)
            if ok then
                for _, o in ipairs(list) do out[#out + 1] = o end
            else
                Log("[WARN] fusion wheel entries failed: " .. tostring(list))
            end
        end
    end
    return out
end
-- All evolution/adaptation options for the currently summoned pal with
-- affordability info - feeds the radial submenu. Returns nil, reason when
-- nothing is available.
-- The middle of the radial is a circle, not a line. A pair with six conditions
-- and nine materials produces roughly 200 characters, so the text is split by
-- kind and each kind wrapped, instead of being handed over as one run that
-- would leave the circle on both sides.
local CENTER_WIDTH = 30
-- The circle has room for a handful of lines, not for a shopping list. Past
-- this the price is summarised instead, so an absurd config cannot push the
-- text out of the ring.
local CENTER_MAX_LINES = 6
-- Greedy word wrap. Breaks on spaces only, so an item name never gets cut in
-- half, and a single word longer than the width stays on its own line rather
-- than being sliced mid-character - cutting by bytes would land inside a
-- multi-byte character in German, Russian or Japanese.
local function wrapText(text, width, out)
    local line = nil
    for word in tostring(text):gmatch("%S+") do
        if not line then
            line = word
        elseif #line + 1 + #word <= width then
            line = line .. " " .. word
        else
            table.insert(out, line)
            line = word
        end
    end
    if line then table.insert(out, line) end
end
-- The requirements of one target as wrapped lines: level, then conditions,
-- then price. The target's own name is left out because the wheel segment
-- already carries it. Costs resolve against the pair's minimum level, the
-- earliest point the price applies, which is the level the guide quotes too.
local function requirementLine(pair, level, worldCtx, param)
    local lines = {}
    -- What KIND of step this is, above the level and the price. A prestige and
    -- an ordinary evolution ask for the same things and cost the same shape of
    -- price, so without a word for it the middle of the wheel reads identically
    -- for a step that resets the Pal and one that does not. Auto-Evo is the
    -- same case from the other side: it does not wait to be picked, and the
    -- colour on the segment only says so to somebody who knows the colour.
    if pair.category == "prestige" then
        wrapText(I18n.msg("prestige"), CENTER_WIDTH, lines)
    end
    if pair.autoEvolve == true then
        wrapText(I18n.msg("autoLockEntry"), CENTER_WIDTH, lines)
    end
    local minLevel = EvoState.requiredLevelFor(pair, param)
    if minLevel > 0 then wrapText(I18n.msg("guideLevelShort", minLevel), CENTER_WIDTH, lines) end

    local cond = Conditions.describe(pair, Config.conditionDisclosure)
    if cond and cond ~= "" then wrapText(cond, CENTER_WIDTH, lines) end

    local okCost, costList = pcall(Costs.resolve, pair, minLevel, worldCtx)
    if okCost and type(costList) == "table" and #costList > 0 then
        local before = #lines
        local okDesc, text = pcall(Costs.describe, costList)
        if okDesc and text and text ~= "" then
            wrapText(text, CENTER_WIDTH, lines)
            -- A price that does not fit is replaced by its own summary rather
            -- than cut mid-list, so the player still learns there is a cost and
            -- how big it is. The full list is on the guide page.
            if #lines > CENTER_MAX_LINES then
                for i = #lines, before + 1, -1 do lines[i] = nil end
                wrapText(I18n.msg("costItemCount", #costList), CENTER_WIDTH, lines)
            end
        end
    end

    if #lines == 0 then return nil end
    -- Last word on the budget. The cost block trims itself above, but the
    -- kind of step, the level and the conditions do not, and together they
    -- pass the cap on their own: two kind lines plus a level plus three
    -- conditions plus a price is eight. What goes is what came last, so the
    -- kind and the level - the two a player reads first - always survive.
    for i = #lines, CENTER_MAX_LINES + 1, -1 do lines[i] = nil end
    return table.concat(lines, "\n")
end
local function evolutionOptions()
    if ServerCheck.blocked() then return nil, I18n.msg("serverNoPalvolveShort") end
    if EvoLock.lockBusy() then return nil, I18n.msg("evolutionRunning") end
    local playerCtx = Role.localPlayerCtx()
    local holder = EvoUtil.findHolderFor(playerCtx, nil)
    local actor = nil
    if holder then pcall(function() actor = holder:TryGetSpawnedOtomo() end) end
    if not (actor and actor:IsValid()) then return nil, I18n.msg("noPalSummoned") end
    local param = EvoUtil.paramOf(actor)
    if not (param and EvoUtil.isOwnedBy(param, playerCtx and playerCtx.playerUId)) then return nil, I18n.msg("noPalSummoned") end
    if Ride.ridingInAir(actor) then return nil, I18n.msg("landFirst") end
    local id, isAlpha = EvoUtil.baseCharacterId(param:GetCharacterID():ToString())
    local pairList, isPrestige, prestigeErr = EvoState.optionPairsFor(id, param)
    if isPrestige and EvoState.prestigeAtMax(param) then
        return nil, I18n.msg("prestigeAtMax", EvoNames.palDisplayName(id))
    end
    if not pairList or #pairList == 0 then
        if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", EvoNames.palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", EvoNames.palDisplayName(id))
    end
    if prestigeErr then Log("Prestige targets unavailable: " .. tostring(prestigeErr)) end
    local level = 0
    pcall(function() level = param:GetLevel() end)
    local condCtx = { actor = actor, param = param, playerCtx = playerCtx, holder = holder }
    local options = {}
    local byTarget = {}
    local conditioned = Config.evolutionMode == "conditioned"
    -- "conditioned" keeps the best-matching target, but per kind: a prestige
    -- and an adaptation are not rivals for the same step. Picked from one pool,
    -- the adaptation listed first always won the tie against a derived prestige,
    -- and a Pal at the end of its line was never offered prestige in this mode.
    local conditionedBest, conditionedBestCount = {}, {}
    local conditionedReason = nil
    for i, pair in ipairs(pairList) do
        -- index is the compact token a connected client sends over the net
        -- channel: the pair's position in Config.findPairs(id), or a prestige
        -- pair's own prestigeIndex (pairIndexFor). The host re-derives the pair
        -- from its own config at this index.
        --
        -- Beside adaptations a prestige entry is named as what it is. Its target
        -- is the family base, and two species names side by side do not say
        -- which of them starts the Pal over.
        local pairIsPrestige = EvoState.isPrestigePair(pair)
        local opt = {
            pair = pair,
            index = EvoState.pairIndexFor(pair, i),
            label = (pairIsPrestige and not isPrestige) and I18n.msg("prestige")
                or EvoNames.palDisplayName(pair.to),
            prestige = pairIsPrestige,
        }
        -- What this target asks for, short enough for a wheel segment and
        -- phrased the same way the guide pages phrase it. Without this the
        -- wheel names targets and nothing else, so the only way to learn what
        -- an evolution costs was to try it and read the refusal.
        opt.requirement = requirementLine(pair, level, holder, param)
        local rulePasses = false
        -- Marked further down once the unlock is known, because an entry that is
        -- open only because the Pal earned it once looks identical to a normally
        -- open one otherwise, and the player would read it as the mod ignoring
        -- its own requirement.

        local unknownReason = EvoUtil.unknownConditionReason(pair)
        if unknownReason then
            opt.blocked = unknownReason
        elseif isAlpha and not EvoUtil.swapTargetId(pair, true) then
            opt.blocked = I18n.msg("noAlphaFormShort", opt.label)
        elseif level < EvoState.requiredLevelFor(pair, param) then
            opt.blocked = I18n.msg("needsLevelShort", opt.label, EvoState.requiredLevelFor(pair, param), level)
        else
            local condOk, unmet = Conditions.evaluate(pair, condCtx)
            -- A target this Pal has already qualified for once stays reachable,
            -- even now that the condition has passed. Most conditions are
            -- transient, so without this "electrified" is only usable by a
            -- player standing at the wheel in that exact second.
            if not condOk and EvoState.AutoUnlock.has(param, pair.to) then
                condOk = true
                opt.unlocked = true
                opt.requirement = I18n.msg("unlockedShort", opt.label)
            end
            if not condOk then
                opt.blocked = I18n.msg("needsConditions", opt.label,
                    EvoUtil.disclosedConditions(pair, unmet))
            else
                rulePasses = true
                local costList = Costs.resolve(pair, level, holder)
                local costOk, missing = Costs.check(playerCtx, costList)
                if not costOk then
                    opt.blocked = I18n.msg("missingItems",
                        opt.label, Costs.describeMissing(missing))
                end
            end
        end
        if Config.devMode then
            Log(string.format("[radial] %s auto=%s blocked=%s unlocked=%s",
                tostring(opt.label), tostring(pair.autoEvolve),
                tostring(opt.blocked), tostring(opt.unlocked)))
        end
        -- Same-target variants (either/or conditions) collapse into ONE wheel
        -- entry: the first unblocked variant wins its index; while every
        -- variant is blocked the reasons are joined so the player sees all
        -- ways to unlock the target.
        if conditioned then
            local kind = pairIsPrestige and "prestige" or "ordinary"
            if rulePasses and EvoUtil.conditionCount(pair) > (conditionedBestCount[kind] or -1) then
                conditionedBest[kind] = opt
                conditionedBestCount[kind] = EvoUtil.conditionCount(pair)
            elseif not rulePasses and not conditionedReason then
                conditionedReason = opt.blocked
            end
        else
            -- A prestige back to the base and an adaptation to that same species
            -- are two different entries, so they cannot share a key.
            local targetKey = (pairIsPrestige and "prestige:" or "") .. pair.to
            local existing = byTarget[targetKey]
            if not existing then
                byTarget[targetKey] = opt
                table.insert(options, opt)
            elseif existing.blocked and not opt.blocked then
                existing.pair = opt.pair
                existing.index = opt.index
                existing.blocked = nil
                existing.requirement = opt.requirement
            elseif existing.blocked and opt.blocked then
                existing.blocked = existing.blocked .. I18n.msg("orJoiner") .. opt.blocked
            end
        end
    end
    if conditioned then
        local best = {}
        if conditionedBest.ordinary then best[#best + 1] = conditionedBest.ordinary end
        if conditionedBest.prestige then best[#best + 1] = conditionedBest.prestige end
        if #best > 0 then return best end
        if conditionedReason then return nil, conditionedReason end
        if isPrestige then return nil, I18n.msg("hasNoPrestige", EvoNames.palDisplayName(id)) end
        return nil, I18n.msg("hasNoEvolution", EvoNames.palDisplayName(id))
    end
    return options
end

EvoWheel.fusionOptions = fusionOptions
EvoWheel.CENTER_WIDTH = CENTER_WIDTH
EvoWheel.CENTER_MAX_LINES = CENTER_MAX_LINES
EvoWheel.wrapText = wrapText
EvoWheel.requirementLine = requirementLine
EvoWheel.evolutionOptions = evolutionOptions

return EvoWheel
