-- Repeating work on the game thread.
--
-- LoopAsync runs its Lua on a worker thread against the same Lua state the
-- game thread's hooks use, and every ExecuteInGameThread from it registers a
-- transient callback. Under a fusion scene's 30 ticks a second that ended in
-- "Ref was not function" in the engine tick, the callback collector freeing
-- callbacks, and an access violation inside UE4SS (client and dedicated server,
-- see UE4SS-LESSONS.md). LoopInGameThreadWithDelay keeps the whole tick on the
-- game thread and registers its callback once.
--
-- Its callback's return value does not end the loop; CancelDelayedAction does.
-- GameLoop.start takes the LoopAsync contract instead: fn returns true to stop.

local GameLoop = {}

local function Log(msg)
    print(string.format("[Palvolve] [loop] %s\n", msg))
end

-- Held here for as long as a loop runs, so its callback is never collected.
local loops = {}

local function stopEntry(entry)
    entry.done = true
    if entry.handle ~= nil then
        local ok, err = pcall(CancelDelayedAction, entry.handle)
        if not ok then Log("[WARN] " .. entry.name .. " not cancelled: " .. tostring(err)) end
        loops[entry.handle] = nil
    end
end

--- Calls fn on the game thread every ms milliseconds until it returns true.
--- An error in fn ends the loop and is logged. Returns the handle, or nil.
function GameLoop.start(ms, fn, name)
    local entry = { fn = fn, name = name or "loop" }
    entry.tick = function()
        if entry.done then return end
        local ok, stop = pcall(entry.fn)
        if not ok then
            Log("[ERROR] " .. entry.name .. " failed and stops: " .. tostring(stop))
            stop = true
        end
        if stop then stopEntry(entry) end
    end
    local ok, handle = pcall(LoopInGameThreadWithDelay, ms, entry.tick)
    if not ok or handle == nil then
        Log("[ERROR] " .. entry.name .. " could not start: " .. tostring(handle))
        return nil
    end
    entry.handle = handle
    -- fn may already have asked to stop on a first tick run inside the call
    if entry.done then
        stopEntry(entry)
        return handle
    end
    loops[handle] = entry
    return handle
end

--- Calls fn once on the game thread after ms milliseconds.
function GameLoop.after(ms, fn, name)
    local entry = { fn = fn, name = name or "delayed call" }
    entry.run = function()
        local ok, err = pcall(entry.fn)
        if not ok then Log("[ERROR] " .. entry.name .. " failed: " .. tostring(err)) end
        return true
    end
    return GameLoop.start(ms, entry.run, entry.name)
end

return GameLoop
