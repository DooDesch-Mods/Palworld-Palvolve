-- Mod Options Framework consumer SDK v1.
-- Copy this file and pmo_json.lua into the consumer mod's Scripts directory.

local json = require("pmo_json")

local client = {
    api_version = 1,
    prefix = "PalModOptions.V1.",
    schema = nil,
    session = nil,
    last_error = nil,
}

local READY_RETRY_DELAYS_MS = { 100, 250, 500, 1000, 2000 }
local RACE_RECOVERY_DELAY_MS = 100
local pending_registrations = {}

local function shared_get(key)
    if ModRef == nil then
        return nil
    end
    local ok, value = pcall(function()
        return ModRef:GetSharedVariable(key)
    end)
    return ok and value or nil
end

local function shared_set(key, value)
    if ModRef == nil then
        return false
    end
    return pcall(function()
        ModRef:SetSharedVariable(key, value)
    end)
end

local function valid_id(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 64
        and value:match("^[A-Za-z0-9_.-]+$") ~= nil
end

local valid_keybinds = {}

for index = 1, 24 do
    valid_keybinds["F" .. tostring(index)] = true
end
for code = string.byte("A"), string.byte("Z") do
    valid_keybinds[string.char(code)] = true
end
for _, name in ipairs({
    "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN",
    "EIGHT", "NINE", "NUM_ZERO", "NUM_ONE", "NUM_TWO", "NUM_THREE",
    "NUM_FOUR", "NUM_FIVE", "NUM_SIX", "NUM_SEVEN", "NUM_EIGHT",
    "NUM_NINE", "BACKSPACE", "TAB", "RETURN", "PAUSE", "CAPS_LOCK",
    "SPACE", "PAGE_UP", "PAGE_DOWN", "END", "HOME", "LEFT_ARROW",
    "UP_ARROW", "RIGHT_ARROW", "DOWN_ARROW", "PRINT_SCREEN", "INS",
    "DEL", "MULTIPLY", "ADD", "SUBTRACT", "DECIMAL", "DIVIDE",
    "NUM_LOCK", "SCROLL_LOCK",
}) do
    valid_keybinds[name] = true
end

local function valid_keybind(value)
    return type(value) == "string" and valid_keybinds[value] == true
end

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, child in pairs(value) do
        result[copy(key, seen)] = copy(child, seen)
    end
    return result
end

local normalize_value

local function defaults(schema)
    local result = {}
    for _, option in ipairs(schema.options or {}) do
        if option.type ~= "section" and type(option.key) == "string" then
            result[option.key] = copy(option.default)
        end
    end
    return result
end

local function initial_values(schema)
    local result = defaults(schema)
    for _, option in ipairs(schema.options or {}) do
        if option.type ~= "section" and type(option.key) == "string" then
            local value = nil
            if type(schema.initial_values) == "table" then
                value = schema.initial_values[option.key]
            end
            local normalized = nil
            if value ~= nil then
                normalized = normalize_value(option, value)
            end
            if normalized ~= nil then
                result[option.key] = normalized
            end
        end
    end
    return result
end

local function constraints_valid(schema, values)
    for _, constraint in ipairs(schema.constraints or {}) do
        local left = values[constraint.left]
        local right = values[constraint.right]
        local valid = constraint.type == "lt" and left < right
            or constraint.type == "lte" and left <= right
            or constraint.type == "gt" and left > right
            or constraint.type == "gte" and left >= right
            or constraint.type == "neq" and left ~= right
        if not valid then
            return false
        end
    end
    return true
end

local function normalize_number(option, value)
    local number = tonumber(value)
    if number == nil or number ~= number
        or number == math.huge or number == -math.huge then
        return nil
    end
    if option.type == "integer" then
        if math.abs(number - math.floor(number + 0.5)) > 0.0000001 then
            return nil
        end
        number = math.floor(number + 0.5)
    end
    local minimum = tonumber(option.minimum)
    local maximum = tonumber(option.maximum)
    local step = tonumber(option.step)
    if minimum ~= nil and number < minimum - 0.0000001 then
        return nil
    end
    if maximum ~= nil and number > maximum + 0.0000001 then
        return nil
    end
    if step ~= nil and step > 0 then
        local origin = minimum or 0
        local ticks = (number - origin) / step
        if math.abs(ticks - math.floor(ticks + 0.5)) > 0.000001 then
            return nil
        end
        number = origin + math.floor(ticks + 0.5) * step
        if option.type == "integer" then
            number = math.floor(number + 0.5)
        end
    end
    return number
end

normalize_value = function(option, value)
    if option.type == "boolean" then
        if type(value) == "boolean" then
            return value
        end
        return nil
    elseif option.type == "integer" or option.type == "number" then
        return normalize_number(option, value)
    elseif option.type == "text" then
        local maximum = math.max(
            1,
            math.min(256, math.floor(tonumber(option.max_length) or 128))
        )
        return type(value) == "string" and #value <= maximum and value or nil
    elseif option.type == "enum" and type(value) == "string" then
        for _, raw_choice in ipairs(option.choices or {}) do
            local choice = type(raw_choice) == "table"
                and raw_choice.value or tostring(raw_choice)
            if choice == value then
                return value
            end
        end
    elseif option.type == "keybind" then
        return valid_keybind(value) and value or nil
    end
    return nil
end

local function load_saved(schema)
    local directory = shared_get(client.prefix .. "ConfigDirectory")
    if type(directory) ~= "string" or directory == "" then
        return initial_values(schema)
    end
    local file = io.open(directory .. "\\" .. schema.id .. ".ini", "r")
    if file == nil then
        return initial_values(schema)
    end
    local values = defaults(schema)
    local by_key = {}
    for _, option in ipairs(schema.options or {}) do
        if option.type ~= "section" and type(option.key) == "string" then
            by_key[option.key] = option
        end
    end
    for line in file:lines() do
        local key, encoded = line:match("^([A-Za-z0-9_.-]+)=(.*)$")
        local option = key ~= nil and by_key[key] or nil
        if option ~= nil then
            local ok, decoded = pcall(json.decode, encoded)
            local normalized = nil
            if ok then
                normalized = normalize_value(option, decoded)
            end
            if normalized ~= nil then
                values[key] = normalized
            end
        end
    end
    file:close()
    if not constraints_valid(schema, values) then
        return defaults(schema)
    end
    return values
end

local function registry_contains(registry, id)
    for registered in tostring(registry or ""):gmatch("[^\r\n]+") do
        if registered == id then
            return true
        end
    end
    return false
end

local function queue_pending_schema(schema, encoded)
    if not shared_set(client.prefix .. "PendingManifest." .. schema.id, encoded) then
        return false, "could not publish the pending option schema"
    end
    local registry_key = client.prefix .. "PendingRegistry"
    local registry = shared_get(registry_key)
    registry = type(registry) == "string" and registry or ""
    if not registry_contains(registry, schema.id) then
        registry = registry .. (registry == "" and "" or "\n") .. schema.id
        if not shared_set(registry_key, registry) then
            return false, "could not publish the pending framework registry"
        end
    end
    return true
end

local function prepare_schema(schema)
    if type(schema) ~= "table" or not valid_id(schema.id) then
        return nil, nil,
            "schema.id must use 1-64 letters, numbers, dots, underscores, or hyphens"
    end
    local prepared = copy(schema)
    prepared.api = client.api_version
    if type(prepared.options) ~= "table" or #prepared.options < 1 then
        return nil, nil, "schema.options must contain at least one option"
    end
    local encoded_ok, encoded = pcall(json.encode, prepared)
    if not encoded_ok then
        return nil, nil, tostring(encoded)
    end
    return prepared, encoded, nil
end

local function readiness_snapshot()
    local session_before = shared_get(client.prefix .. "Session")
    local api_version = tonumber(shared_get(client.prefix .. "ApiVersion"))
    local config_directory =
        shared_get(client.prefix .. "ConfigDirectory")
    local registry = nil
    if type(session_before) == "string" and session_before ~= "" then
        registry = shared_get(
            client.prefix .. "Registry." .. session_before
        )
    end
    local session_after = shared_get(client.prefix .. "Session")
    if api_version ~= client.api_version
        or type(session_before) ~= "string"
        or session_before == ""
        or session_before ~= session_after
        or type(config_directory) ~= "string"
        or config_directory == ""
        or type(registry) ~= "string" then
        return nil
    end
    return {
        api_version = api_version,
        session = session_before,
        config_directory = config_directory,
    }
end

local function same_snapshot(left, right)
    return left ~= nil
        and right ~= nil
        and left.api_version == right.api_version
        and left.session == right.session
        and left.config_directory == right.config_directory
end

local function register_prepared(schema, encoded, expected_session)
    local session = shared_get(client.prefix .. "Session")
    if type(session) ~= "string" or session == "" then
        local queued, queue_error = queue_pending_schema(schema, encoded)
        client.last_error = queued and "queued" or queue_error
        return nil, client.last_error
    end
    if expected_session ~= nil and session ~= expected_session then
        client.last_error = "queued"
        return nil, client.last_error
    end
    client.session = session
    if not shared_set(
        client.prefix .. "Manifest." .. session .. "." .. schema.id,
        encoded
    ) then
        client.last_error = "could not publish the option schema"
        return nil, client.last_error
    end
    local registry_key = client.prefix .. "Registry." .. session
    local registry = shared_get(registry_key)
    registry = type(registry) == "string" and registry or ""
    if not registry_contains(registry, schema.id) then
        registry = registry .. (registry == "" and "" or "\n") .. schema.id
        if not shared_set(registry_key, registry) then
            client.last_error = "could not publish the framework registry"
            return nil, client.last_error
        end
    end
    client.schema = copy(schema)
    local initial = load_saved(client.schema)
    shared_set(
        client.prefix .. "Values." .. session .. "." .. client.schema.id,
        json.encode(initial)
    )
    local generation_key = client.prefix
        .. "Generation." .. session .. "." .. client.schema.id
    if shared_get(generation_key) == nil then
        shared_set(generation_key, 0)
    end
    client.last_error = nil
    return initial
end

function client.available()
    return readiness_snapshot() ~= nil
end

function client.capture_active()
    return shared_get(client.prefix .. "CaptureActive") == true
end

function client.register(schema)
    client.last_error = nil
    local prepared, encoded, prepare_error = prepare_schema(schema)
    if prepared == nil then
        client.last_error = prepare_error
        return nil, client.last_error
    end
    return register_prepared(prepared, encoded)
end

-- Registers after a bounded startup settlement fence. A replacement Session
-- is fresh proof immediately; a retained Session is quarantined for the full
-- startup window. At most one delayed action is alive, and no tick hook or
-- permanent poll is created.
function client.register_when_ready(schema, completion_callback)
    client.last_error = nil
    if type(completion_callback) ~= "function" then
        client.last_error = "completion_callback must be a function"
        return false, client.last_error
    end

    local delivered = false
    local function deliver(settings, registration_error)
        if delivered then
            return
        end
        delivered = true
        local ok, callback_error = pcall(
            completion_callback,
            settings,
            registration_error
        )
        if not ok then
            client.last_error =
                "completion callback failed: " .. tostring(callback_error)
            print("[PalModOptionsClient] " .. client.last_error .. "\n")
        end
    end

    local prepared, encoded, prepare_error = prepare_schema(schema)
    if prepared == nil then
        client.last_error = prepare_error
        deliver(nil, prepare_error)
        return false, prepare_error
    end
    if pending_registrations[prepared.id] ~= nil then
        local duplicate_error =
            "registration is already pending for " .. prepared.id
        client.last_error = duplicate_error
        deliver(nil, duplicate_error)
        return false, duplicate_error
    end
    local queued, queue_error = queue_pending_schema(prepared, encoded)
    if not queued then
        client.last_error = queue_error
        deliver(nil, queue_error)
        return false, queue_error
    end

    local initial_snapshot = readiness_snapshot()
    local operation = {
        done = false,
        next_delay = 1,
        schema = prepared,
        encoded = encoded,
        initial_snapshot = initial_snapshot,
        race_recovery_available = true,
    }
    pending_registrations[prepared.id] = operation

    local retry
    local function finish(resolved_settings, resolved_error)
        if operation.done then
            return
        end
        operation.done = true
        pending_registrations[prepared.id] = nil
        client.last_error = resolved_error
        deliver(resolved_settings, resolved_error)
    end

    local function schedule_next(after_detected_race)
        local delay_ms = READY_RETRY_DELAYS_MS[operation.next_delay]
        if delay_ms == nil then
            if after_detected_race and operation.race_recovery_available then
                operation.race_recovery_available = false
                delay_ms = RACE_RECOVERY_DELAY_MS
            else
                finish(nil, "framework unavailable after startup retry window")
                return false, client.last_error
            end
        end
        if READY_RETRY_DELAYS_MS[operation.next_delay] ~= nil then
            operation.next_delay = operation.next_delay + 1
        end
        if type(ExecuteInGameThreadWithDelay) ~= "function" then
            finish(nil, "delayed-action API unavailable")
            return false, client.last_error
        end
        local scheduled, schedule_error = pcall(
            ExecuteInGameThreadWithDelay,
            delay_ms,
            retry
        )
        if not scheduled then
            finish(
                nil,
                "could not schedule framework readiness check: "
                    .. tostring(schedule_error)
            )
            return false, client.last_error
        end
        return true
    end

    retry = function()
        if operation.done then
            return
        end
        local current_snapshot = readiness_snapshot()
        if current_snapshot ~= nil then
            local fresh_session =
                operation.initial_snapshot == nil
                or not same_snapshot(
                    operation.initial_snapshot,
                    current_snapshot
                )
            local final_startup_check =
                operation.next_delay > #READY_RETRY_DELAYS_MS
            if fresh_session or final_startup_check then
                local resolved, resolved_error = register_prepared(
                    operation.schema,
                    operation.encoded,
                    current_snapshot.session
                )
                if resolved ~= nil then
                    local confirmed_snapshot = readiness_snapshot()
                    if same_snapshot(
                        current_snapshot,
                        confirmed_snapshot
                    ) then
                        finish(resolved, nil)
                        return
                    end
                    schedule_next(true)
                    return
                elseif resolved_error ~= "queued" then
                    finish(nil, resolved_error)
                    return
                else
                    schedule_next(true)
                    return
                end
            end
        end
        schedule_next(false)
    end

    local scheduled, schedule_error = schedule_next()
    return scheduled, scheduled and "queued" or schedule_error
end

function client.get(key)
    if client.schema == nil then
        return nil, "register must be called first"
    end
    local source = shared_get(
        client.prefix .. "Values." .. client.session .. "." .. client.schema.id
    )
    local values = nil
    if type(source) == "string" then
        local ok, decoded = pcall(json.decode, source)
        if ok and type(decoded) == "table" then
            values = decoded
        end
    end
    values = values or load_saved(client.schema)
    if key ~= nil then
        return values[key]
    end
    return values
end

function client.generation()
    if client.schema == nil then
        return 0
    end
    return math.max(
        0,
        math.floor(
            tonumber(shared_get(
                client.prefix .. "Generation."
                    .. client.session .. "." .. client.schema.id
            )) or 0
        )
    )
end

-- Call sync only from an event the consumer mod already owns, such as its
-- operation handler or actor lifecycle callback. It creates no timer or poll.
function client.sync(previous_generation, apply_callback)
    local generation = client.generation()
    if generation == tonumber(previous_generation) then
        return generation, false, client.get()
    end
    local values = client.get()
    if type(apply_callback) == "function" then
        local ok, callback_error = pcall(apply_callback, values, generation)
        if not ok then
            client.last_error = tostring(callback_error)
            return previous_generation, false, values, client.last_error
        end
    end
    return generation, true, values
end

function client.error()
    return client.last_error
end

return client
