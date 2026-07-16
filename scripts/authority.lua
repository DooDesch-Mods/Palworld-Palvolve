-- authority.lua: single entry point for world-authoritative mod requests.
-- The implementation lives in evolution.lua and is bound at init (a direct
-- require in both directions would be circular). In-process callers
-- (standalone/listen host) call requestEvolve directly; the network layer
-- of a later phase decodes transport requests, runs its security checks
-- (sender-derived ownership, request-id replay cache, rate limit) and then
-- calls the same entry.
local Authority = {}

local impl = nil

function Authority.bind(fns)
    impl = fns
end

-- Returns ok, message (message is player-facing on failure).
function Authority.requestEvolve(playerCtx, fromId, toId)
    if not (impl and impl.evolve) then
        return false, "Authority not ready"
    end
    return impl.evolve(playerCtx, fromId, toId)
end

return Authority
