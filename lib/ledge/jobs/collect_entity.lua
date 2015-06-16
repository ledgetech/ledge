local pairs, unpack = pairs, unpack
local tbl_insert = table.insert


local _M = {
    _VERSION = '0.01',
}


-- Cleans up expired items and keeps track of memory usage.
function _M.perform(job)
    local redis = job.redis
    if not redis then
        return nil, "job-error", "no redis connection provided"
    end

    local ok = redis:multi()

    local del_keys = {}
    for _, key in pairs(job.data.entity_keys) do
        tbl_insert(del_keys, key)
    end

    local res, err = redis:del(unpack(del_keys))

    -- Decrement the integer value of a key by the given number, only if the key exists,
    -- and only if the current value is a positive integer.
    -- Params: key, decrement
    -- Return: (integer): the value of the key after the operation.
    local POSDECRBYX = [[
        local value = redis.call("GET", KEYS[1])
        if value and tonumber(value) > 0 then
            return redis.call("DECRBY", KEYS[1], ARGV[1])
        else
            return 0
        end
    ]]

    res, err = redis:eval(POSDECRBYX, 1, job.data.cache_key_chain.memused, job.data.size)
    res, err = redis:zrem(job.data.cache_key_chain.entities, job.data.entity_keys.main)

    res, err = redis:exec()

    if res then
        -- Verify return values look sane.
        if res[1] ~= #del_keys or res[2] < 0 then
            return nil, "job-error", "entity " .. job.data.entity_keys.main .. " was not collected. " ..
            "#del_keys: " .. #del_keys .. "; del: " .. res[1] .. "; decrby: " .. res[2] .. "; zrem: " .. res[3]
        else
            return true, nil
        end
    else
        return nil, "redis-error", err
    end
end


return _M

