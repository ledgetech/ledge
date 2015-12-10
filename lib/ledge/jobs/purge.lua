local redis_connector = require "resty.redis.connector"
local ledge = require "ledge.ledge"

local ipairs, tonumber = ipairs, tonumber
local str_len = string.len
local str_sub = string.sub
local ngx_null = ngx.null

local _M = {
    _VERSION = '0.01',
}


-- Scans the keyspace for keys which match, and expires them. We do this against
-- the slave Redis instance if available.
function _M.perform(job)
    local redis = job.redis
    local redis_params = job.redis_params
    local redis_connection_options = job.redis_connection_options

    -- Try to connect to a slave for SCAN commands.
    local rc = redis_connector.new()
    rc:set_connect_timeout(redis_connection_options.connect_timeout)
    rc:set_read_timeout(redis_connection_options.read_timeout)
    redis_params.role = "slave"

    local redis_slave, err = rc:connect(redis_params)
    if not redis_slave then
        -- Use the existing connection
        redis_slave = redis
    end

    if not redis then
        return nil, "job-error", "no redis connection provided"
    end

    -- This runs recursively using the SCAN cursor, until the entire keyspace
    -- has been scanned.
    local res, err = _M.expire_pattern(
        redis,
        redis_slave,
        0,
        job.data.key_chain,
        job.data.keyspace_scan_count,
        job
    )

    if res ~= nil then
        return true, nil
    else
        return nil, "redis-error", err
    end
end


-- Scans the keyspace based on a pattern (asterisk) present in the main key,
-- including the ::key suffix to denote the main key entry.
-- (i.e. one per entry)
-- args:
--  redis: master redis connection
--  redis_slave: slave (may actually be master) for running expensive scan commands
--  cursor: the scan cursor, updated for each iteration
--  key_chain: key chain containing the patterned key to scan for
--  count: the scan count size
function _M.expire_pattern(redis, redis_slave, cursor, key_chain, count, job)
    local res, err = redis_slave:scan(
        cursor,
        "MATCH", key_chain.key,
        "COUNT", count
    )

    if job:ttl() < 10 then
        if not job:heartbeat() then
            return false, "Failed to heartbeat job"
        end
    end

    if not res or res == ngx_null then
        return nil, err
    else
        for _,key in ipairs(res[2]) do
            local entity = redis:get(key)
            if entity then
                -- Remove the ::key part to give the cache_key without a suffix
                local cache_key = str_sub(key, 1, -(str_len("::key") + 1))
                local res = ledge.expire_keys(nil,
                    redis,
                    ledge.key_chain(nil, cache_key), -- a keychain for this key
                    ledge.entity_keys(nil, cache_key .. "::" .. entity) -- the entity keys for the live entity
                )
            end
        end

        local cursor = tonumber(res[1])
        if cursor > 0 then
            -- If we have a valid cursor, recurse to move on.
            return _M.expire_pattern(redis, redis_slave, cursor, key_chain, count, job)
        end

        return true
    end
end


return _M
