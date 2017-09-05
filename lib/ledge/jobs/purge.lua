local redis_connector = require "resty.redis.connector"
local response = require "ledge.response"
local ipairs, tonumber = ipairs, tonumber
local str_len = string.len
local str_sub = string.sub
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null
local ngx_md5 = ngx.md5
local tbl_getn = table.getn

local purge = require("ledge.purge").purge
local create_redis_slave_connection = require("ledge").create_redis_slave_connection
local close_redis_connection = require("ledge").close_redis_connection

local _M = {
    _VERSION = "2.0.1",
}


-- Scans the keyspace for keys which match, and expires them. We do this against
-- the slave Redis instance if available.
function _M.perform(job)
    if not job.redis then
        return nil, "job-error", "no redis connection provided"
    end

    local slave, err = create_redis_slave_connection()
    if not slave then
        job.redis_slave = job.redis
    else
        job.redis_slave = slave
    end

    -- This runs recursively using the SCAN cursor, until the entire keyspace
    -- has been scanned.
    local res, err = _M.expire_pattern(0, job)

    if slave then
        close_redis_connection(slave)
    end

    if not res then
        return nil, "redis-error", err
    end
end


-- Scans the keyspace based on a pattern (asterisk), and runs a purge for each cache entry
function _M.expire_pattern(cursor, job)
    if job:ttl() < 10 then
        if not job:heartbeat() then
            return false, "Failed to heartbeat job"
        end
    end

    -- Scan using the "main" key to get a single key per cache entry
    local res, err = job.redis_slave:scan(
        cursor,
        "MATCH", job.data.key_chain.main,
        "COUNT", job.data.keyspace_scan_count
    )

    if not res or res == ngx_null then
        return nil, "SCAN error: " .. tostring(err)
    else
        if tbl_getn(res[2]) > 0 then
            local handler = require("ledge").create_handler()
            handler.redis = require("ledge").create_redis_connection()
            handler.storage = require("ledge").create_storage_connection(
                job.data.storage_driver,
                job.data.storage_driver_config
            )

            for _,key in ipairs(res[2]) do
                -- Strip the "main" suffix to find the cache key
                local cache_key = str_sub(key, 1, -(str_len("::main") + 1))
                handler._cache_key = cache_key

                local ok, err = purge(handler, job.data.purge_mode)
                if ok == nil and err then ngx_log(ngx_ERR, tostring(err)) end

                -- reset these so that handler can be reused
                handler._cache_key_chain = {}
                handler._cache_key = ""
            end
        end

        local cursor = tonumber(res[1])
        if cursor == 0 then
            return true
        end

        -- If we have a valid cursor, recurse to move on.
        return _M.expire_pattern(cursor, job)
    end
end


return _M
