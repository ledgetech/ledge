local cjson = require "cjson"
local qless = require "resty.qless"

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
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
    res, err = redis:decrby(job.data.cache_key .. ":memused", job.data.size)
    res, err = redis:zrem(job.data.cache_key .. ":entities", job.data.entity_keys.main)

    res, err = redis:exec()

    if res then
        -- Verify return values look sane.
        if res[1] ~= #del_keys or res[2] < 0 or res[3] == 0 then
            return nil, "job-error", "entity " .. job.data.entity_keys.main .. " was not collected"
        else
            return true, nil
        end
    else
        return nil, "redis-error", err
    end
end


return _M

