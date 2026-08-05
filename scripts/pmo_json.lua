-- Mod Options Framework JSON codec.
-- Deliberately data-only: it never evaluates Lua source.

local json = {}

local function encode_string(value)
    local escapes = {
        ['"'] = '\\"',
        ['\\'] = '\\\\',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t',
    }
    return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
        return escapes[character] or string.format("\\u%04x", character:byte())
    end) .. '"'
end

local function is_array(value)
    local count = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        count = math.max(count, key)
    end
    for index = 1, count do
        if value[index] == nil then
            return false
        end
    end
    return true, count
end

local function encode_value(value, stack)
    local value_type = type(value)
    if value == nil then
        return "null"
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("cannot encode a non-finite number")
        end
        return string.format("%.17g", value)
    elseif value_type == "string" then
        return encode_string(value)
    elseif value_type ~= "table" then
        error("cannot encode JSON value of type " .. value_type)
    end

    if stack[value] then
        error("cannot encode a cyclic table")
    end
    stack[value] = true
    local array, count = is_array(value)
    local parts = {}
    if array then
        for index = 1, count do
            parts[index] = encode_value(value[index], stack)
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key, _ in pairs(value) do
        if type(key) ~= "string" then
            error("JSON object keys must be strings")
        end
        table.insert(keys, key)
    end
    table.sort(keys)
    for index, key in ipairs(keys) do
        parts[index] = encode_string(key) .. ":" .. encode_value(value[key], stack)
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function json.encode(value)
    return encode_value(value, {})
end

local function utf8_character(codepoint)
    if codepoint <= 0x7f then
        return string.char(codepoint)
    elseif codepoint <= 0x7ff then
        return string.char(
            0xc0 + math.floor(codepoint / 0x40),
            0x80 + codepoint % 0x40
        )
    elseif codepoint <= 0xffff then
        return string.char(
            0xe0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    elseif codepoint <= 0x10ffff then
        return string.char(
            0xf0 + math.floor(codepoint / 0x40000),
            0x80 + math.floor(codepoint / 0x1000) % 0x40,
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40
        )
    end
    error("invalid Unicode codepoint")
end

local function decoder(source)
    return {
        source = source,
        index = 1,
        length = #source,
    }
end

local function skip_whitespace(state)
    local _, finish = state.source:find("^[ \t\r\n]*", state.index)
    state.index = (finish or state.index - 1) + 1
end

local parse_value

local function parse_string(state)
    if state.source:sub(state.index, state.index) ~= '"' then
        error("expected JSON string at byte " .. state.index)
    end
    state.index = state.index + 1
    local parts = {}
    local start = state.index
    while state.index <= state.length do
        local character = state.source:sub(state.index, state.index)
        if character == '"' then
            table.insert(parts, state.source:sub(start, state.index - 1))
            state.index = state.index + 1
            return table.concat(parts)
        elseif character == "\\" then
            table.insert(parts, state.source:sub(start, state.index - 1))
            local escape = state.source:sub(state.index + 1, state.index + 1)
            local simple = {
                ['"'] = '"',
                ['\\'] = '\\',
                ['/'] = '/',
                b = '\b',
                f = '\f',
                n = '\n',
                r = '\r',
                t = '\t',
            }
            if simple[escape] ~= nil then
                table.insert(parts, simple[escape])
                state.index = state.index + 2
            elseif escape == "u" then
                local hex = state.source:sub(state.index + 2, state.index + 5)
                if not hex:match("^%x%x%x%x$") then
                    error("invalid Unicode escape at byte " .. state.index)
                end
                local codepoint = tonumber(hex, 16)
                state.index = state.index + 6
                if codepoint >= 0xd800 and codepoint <= 0xdbff
                    and state.source:sub(state.index, state.index + 1) == "\\u" then
                    local low_hex = state.source:sub(state.index + 2, state.index + 5)
                    local low = low_hex:match("^%x%x%x%x$") and tonumber(low_hex, 16) or nil
                    if low ~= nil and low >= 0xdc00 and low <= 0xdfff then
                        codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
                        state.index = state.index + 6
                    end
                end
                table.insert(parts, utf8_character(codepoint))
            else
                error("invalid escape at byte " .. state.index)
            end
            start = state.index
        elseif character:byte() < 32 then
            error("control character in JSON string at byte " .. state.index)
        else
            state.index = state.index + 1
        end
    end
    error("unterminated JSON string")
end

local function parse_number(state)
    local token = state.source:sub(state.index):match(
        "^-?%d+%.?%d*[eE]?[+-]?%d*"
    )
    local value = token ~= nil and tonumber(token) or nil
    if value == nil or token == "" then
        error("invalid JSON number at byte " .. state.index)
    end
    state.index = state.index + #token
    return value
end

local function parse_array(state)
    state.index = state.index + 1
    skip_whitespace(state)
    local result = {}
    if state.source:sub(state.index, state.index) == "]" then
        state.index = state.index + 1
        return result
    end
    while true do
        table.insert(result, parse_value(state))
        skip_whitespace(state)
        local character = state.source:sub(state.index, state.index)
        if character == "]" then
            state.index = state.index + 1
            return result
        elseif character ~= "," then
            error("expected ',' or ']' at byte " .. state.index)
        end
        state.index = state.index + 1
        skip_whitespace(state)
    end
end

local function parse_object(state)
    state.index = state.index + 1
    skip_whitespace(state)
    local result = {}
    if state.source:sub(state.index, state.index) == "}" then
        state.index = state.index + 1
        return result
    end
    while true do
        local key = parse_string(state)
        skip_whitespace(state)
        if state.source:sub(state.index, state.index) ~= ":" then
            error("expected ':' at byte " .. state.index)
        end
        state.index = state.index + 1
        skip_whitespace(state)
        result[key] = parse_value(state)
        skip_whitespace(state)
        local character = state.source:sub(state.index, state.index)
        if character == "}" then
            state.index = state.index + 1
            return result
        elseif character ~= "," then
            error("expected ',' or '}' at byte " .. state.index)
        end
        state.index = state.index + 1
        skip_whitespace(state)
    end
end

parse_value = function(state)
    skip_whitespace(state)
    local character = state.source:sub(state.index, state.index)
    if character == '"' then
        return parse_string(state)
    elseif character == "{" then
        return parse_object(state)
    elseif character == "[" then
        return parse_array(state)
    elseif character == "-" or character:match("%d") then
        return parse_number(state)
    elseif state.source:sub(state.index, state.index + 3) == "true" then
        state.index = state.index + 4
        return true
    elseif state.source:sub(state.index, state.index + 4) == "false" then
        state.index = state.index + 5
        return false
    elseif state.source:sub(state.index, state.index + 3) == "null" then
        state.index = state.index + 4
        return nil
    end
    error("unexpected JSON token at byte " .. state.index)
end

function json.decode(source)
    if type(source) ~= "string" then
        error("JSON source must be a string")
    end
    local state = decoder(source)
    local value = parse_value(state)
    skip_whitespace(state)
    if state.index <= state.length then
        error("trailing JSON data at byte " .. state.index)
    end
    return value
end

return json
