-- Palvolve i18n: resolves the game's UI language once and serves localized
-- message templates, condition labels and element names from the baked
-- catalog (i18n_static.lua, generated from the web editor locales). Every
-- lookup falls back to English per key, and a failed format falls back to
-- the English template, so a hole in a catalog can never break a message.
--
-- Per-client semantics: this runs in each client's own Lua state, so radial
-- reasons and local chat lines follow that client's game language. Messages
-- built on the AUTHORITY for a remote requester (co-op reject reasons) use
-- the host's language - documented behavior.

local Catalog = require("i18n_static")

local I18n = {}

local KNOWN = {
    "en", "de", "ja", "zh-Hans", "zh-Hant", "ko", "fr", "it", "es", "es-MX",
    "pt-BR", "ru", "pl", "tr", "th", "vi", "id",
}

-- maps an engine culture code ("de-DE", "zh-Hans-CN", "es-419") to a catalog key
local function normalize(code)
    local lower = tostring(code or ""):lower()
    if lower == "" then return "en" end
    if lower:find("zh", 1, true) == 1 then
        if lower:find("hant") or lower:find("tw") or lower:find("hk") or lower:find("mo") then
            return "zh-Hant"
        end
        return "zh-Hans"
    end
    for _, known in ipairs(KNOWN) do
        if lower == known:lower() then return known end
    end
    if lower:find("es") == 1 and (lower:find("419") or lower:find("mx")) then return "es-MX" end
    if lower:find("pt") == 1 then return "pt-BR" end
    local prefix = lower:match("^([a-z]+)")
    for _, known in ipairs(KNOWN) do
        if known:lower() == prefix then return known end
    end
    return "en"
end

local cachedLang = nil

-- current catalog language; detection is engine state and process-static,
-- so the first successful read is cached
function I18n.lang()
    if cachedLang then return cachedLang end
    local code = nil
    pcall(function()
        local lib = StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
        if lib and lib:IsValid() then
            local s = lib:GetCurrentLanguage()
            if type(s) == "string" then
                code = s
            elseif s ~= nil then
                pcall(function() code = s:ToString() end)
            end
        end
    end)
    if code and code ~= "" then
        cachedLang = normalize(code)
        return cachedLang
    end
    return "en" -- not cached: retry once the engine is further along
end

local function catalogFor(lang)
    return Catalog[lang] or Catalog.en
end

-- message template lookup + format; nil-safe on every level
function I18n.msg(key, ...)
    local lang = I18n.lang()
    local cat = catalogFor(lang)
    local template = (cat.messages and cat.messages[key])
        or (Catalog.en.messages and Catalog.en.messages[key])
    if not template then return key end
    local ok, formatted = pcall(string.format, template, ...)
    if ok then return formatted end
    local okEn, formattedEn = pcall(string.format, Catalog.en.messages[key] or key, ...)
    return okEn and formattedEn or key
end

-- localized label for a boolean condition id (nil when unknown)
function I18n.condition(id)
    local cat = catalogFor(I18n.lang())
    return (cat.conditions and cat.conditions[id])
        or (Catalog.en.conditions and Catalog.en.conditions[id])
end

-- localized element display name ("Dragon" -> "Drache")
function I18n.element(name)
    local cat = catalogFor(I18n.lang())
    return (cat.elements and cat.elements[name])
        or (Catalog.en.elements and Catalog.en.elements[name])
        or name
end

return I18n
