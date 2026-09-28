local sourceRoot = (... and ... ~= "") and ... or "."
package.path = sourceRoot .. "/scripts/?.lua;" .. package.path

local ok, SafePresentation = pcall(require, "remote_presentation")
if not ok then
    print("FAIL: safe multiplayer presentation is not implemented")
    os.exit(1)
end

local recalled = 0
local function recall()
    recalled = recalled + 1
end

local consumedStart = SafePresentation.consume(
    "start",
    { mode = "adaptation", from = "BerryGoat", to = "BerryGoat_Dark" },
    recall
)

if consumedStart ~= true or recalled ~= 1 then
    print("FAIL: a normal multiplayer start must recall exactly once without running FX")
    os.exit(1)
end

local consumedReveal = SafePresentation.consume("reveal", nil, recall)
if consumedReveal ~= true or recalled ~= 1 then
    print("FAIL: reveal must be consumed without a second recall")
    os.exit(1)
end

local consumedPreview = SafePresentation.consume(
    "start",
    { mode = "prestigepreview" },
    recall
)
if consumedPreview ~= false or recalled ~= 1 then
    print("FAIL: non-evolution preview signals must keep their existing presentation")
    os.exit(1)
end

print("PASS: safe multiplayer presentation recalls once and skips unstable evolution FX")
