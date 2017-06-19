local redis_connector = require "resty.redis.connector"
local response = require "ledge.response"
local qless = require "resty.qless"

local ipairs, tonumber = ipairs, tonumber
local str_len = string.len
local str_sub = string.sub
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null
local ngx_md5 = ngx.md5
local tbl_getn = table.getn

local purge = require("ledge.purge").purge

local _M = {
    _VERSION = '1.28.5',
}


-- Scans the keyspace for keys which match, and expires them. We do this against
-- the slave Redis instance if available.
function _M.perform(job)
    --[[
    -- Try to connect to a slave for SCAN commands.
    local rc = redis_connector.new()
    rc:set_connect_timeout(job.redis_connection_options.connect_timeout)
    rc:set_read_timeout(job.redis_connection_options.read_timeout)
    job.redis_params.role = "slave"

    job.redis_slave = rc:connect(job.redis_params)
    job.redis_params.role = "master" -- switch params back to master
    ]]--
    if not job.redis_slave then job.redis_slave = job.redis end -- in case there is no slave

    if not job.redis then
        return nil, "job-error", "no redis connection provided"
    end

    -- This runs recursively using the SCAN cursor, until the entire keyspace
    -- has been scanned.
    local res, err = _M.expire_pattern(0, job)

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
            -- TODO this needs to come from serialised job data?
            handler.storage = require("ledge").create_storage_connection()

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
