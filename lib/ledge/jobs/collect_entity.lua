local pairs, unpack = pairs, unpack
local tbl_insert = table.insert
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR


local _M = {
    _VERSION = '1.28',
}


-- Cleans up expired items and keeps track of memory usage.
function _M.perform(job)
    local redis = job.redis
    if not redis then
        return nil, "job-error", "no redis connection provided"
    end

    local ok = redis:multi()

    local del_keys = {}
    for _, key in pairs(job.data.entity_key_chain) do
        tbl_insert(del_keys, key)
    end

    local res, err = redis:del(unpack(del_keys))

    -- Decrement the integer value of a key by the given number, only if the key exists,
    -- and only if the current value is a positive integer.
    -- Params: key, decrement
    -- Return: (integer): the value of the key after the operation.
    local POSDECRBYX = [[
        local value = redis.call("HGET", KEYS[1], ARGV[1])
        if value and tonumber(value) > 0 then
            return redis.call("HINCRBY", KEYS[1], ARGV[1], -ARGV[2])
        else
            return 0
        end
    ]]

    res, err = redis:eval(POSDECRBYX, 1, job.data.cache_key_chain.main, "memused", job.data.size)
    if not res then ngx_log(ngx_ERR, err) end

    res, err = redis:zrem(job.data.cache_key_chain.entities, job.data.entity_id)
    if not res then ngx_log(ngx_ERR, err) end

    res, err = redis:exec()

    if not res then
        return nil, "redis-error", err
    end
end


return _M

