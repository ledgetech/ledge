local _M = {
    _VERSION = "1.28.3",
}

-- Attempts to set a lock key in redis. The lock will expire after
-- the expiry value if it is not cleared (i.e. in case of errors).
-- Returns true if the lock was acquired, false if the lock already
-- exists, and nil, err in case of failure.
local function acquire_lock(redis, lock_key, timeout)
    -- We use a Lua script to emulate SETNEX (set if not exists with expiry).
    -- This avoids a race window between the GET / SETEX.
    -- Params: key, expiry
    -- Return: OK or BUSY
    local SETNEX = [[
    local lock = redis.call("GET", KEYS[1])
    if not lock then
        return redis.call("PSETEX", KEYS[1], ARGV[1], "locked")
    else
        return "BUSY"
    end
    ]]

    local res, err = redis:eval(SETNEX, 1, lock_key, timeout)

    if not res then -- Lua script failed
        return nil, err
    elseif res == "OK" then -- We have the lock
        return true
    elseif res == "BUSY" then -- Lock is busy
        return false
    end
end
_M.acquire_lock = acquire_lock

return _M
