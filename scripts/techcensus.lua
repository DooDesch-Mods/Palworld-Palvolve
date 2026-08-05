-- Saddle-tech census - RETIRED on build 100933 (v1.7.7).
--
-- The staged ladder (v1.7.6) did its job and convicted the entire runtime
-- read route with flush-safe crumbs across two sessions:
--   * GetRecipeTechlonogy's BY-VALUE row return natively faults (crumb file
--     ended at "entering probe" with no survival line; CTDs at 20:53 and
--     21:33 on 2026-07-29, shared stack hash 4CF1797A - pcall-transparent,
--     the wrapper-construction fault class).
--   * The names ARRAY returns a count (n=589) but its ELEMENTS do not
--     marshal either: every names[i]:ToString() failed, so the keys-only
--     dump contains only "row<i>" fallbacks - no extractable content.
-- LAW: on this build, UPalTechnologyData's reflected getters are count-only
-- from Lua. Do NOT re-enable any stage of this census until a new game
-- build + toolchain revalidates the marshaling (probe-first, single call,
-- crumb-bracketed - the ladder pattern in git history at v1.7.6).
--
-- The saddle-sync feature proceeds WITHOUT runtime reads: the technology
-- row keys come from community datatable dumps pinned as a static table
-- (the elements_static/boss_static house pattern), and the override ships
-- through the PalSchema data half (DT_TechnologyRecipeUnlock -> rowKey ->
-- LevelCap - the PalSync MiscChanges.jsonc template). In-game verification
-- is one glance at a moved saddle tier.
--
-- init is a deliberate no-op that says so once in devMode; the module is
-- kept (rather than deleted) so the conviction record travels with the
-- code that earned it, and so a future revalidation has the harness shape
-- one git checkout away.
local Config = require("config")

local TechCensus = {}

function TechCensus.init()
    if Config.devMode then
        print("[Palvolve] [techcensus] retired on this build "
            .. "(runtime tech-table reads convicted of CTDs; "
            .. "saddle-sync uses static keys + PalSchema)\n")
    end
end

return TechCensus
