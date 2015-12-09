local ledge = require "ledge.ledge"

local pairs, unpack = pairs, unpack
local tbl_insert = table.insert
local str_len = string.len
local str_sub = string.sub
local ngx_null = ngx.null


local _M = {
    _VERSION = '0.01',
}


-- Cleans up expired items and keeps track of memory usage.
function _M.perform(job)
    local redis = job.redis
    if not redis then
        return nil, "job-error", "no redis connection provided"
    end

    local res, err = _M.expire_pattern(
        redis,
        0,
        job.data.key_chain,
        job.data.keyspace_scan_count,
        false
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
--  cursor: the scan cursor, updated for each iteration
--  key_chain: key chain containing the patterned key to scan for
--  count: the scan count size
function _M.expire_pattern(redis, cursor, key_chain, count)
    local res, err = redis:scan(
        cursor,
        "MATCH", key_chain.key,
        "COUNT", count
    )

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
            return _M.expire_pattern(redis, cursor, key_chain, count, expired)
        end

        return true
    end
end


return _M
