local redis_connector = require "resty.redis.connector"
local ledge = require "ledge.ledge"
local qless = require "resty.qless"

local ipairs, tonumber = ipairs, tonumber
local str_len = string.len
local str_sub = string.sub
local ngx_null = ngx.null
local ngx_md5 = ngx.md5

local _M = {
    _VERSION = '0.01',
}


-- Scans the keyspace for keys which match, and expires them. We do this against
-- the slave Redis instance if available.
function _M.perform(job)
    local redis = job.redis
    local redis_params = job.redis_params
    local redis_connection_options = job.redis_connection_options
    local redis_qless_database = job.redis_qless_database

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
        redis_params,
        redis_qless_database,
        0,
        job.data.key_chain,
        job.data.keyspace_scan_count,
        job,
        job.data.revalidate,
        job.data.delete
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
--  job: the qless job
--  revalidate: whether to schedule a background revalidate
--  delete: whether to hard delete rather than expire
function _M.expire_pattern(redis, redis_slave, redis_params, redis_qless_database, cursor,
                            key_chain, count, job, revalidate, delete)
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
            if entity and entity ~= ngx_null then
                -- Remove the ::key part to give the cache_key without a suffix
                local cache_key = str_sub(key, 1, -(str_len("::key") + 1))
                -- the entity keys for the live entity
                local entity_keys = ledge.entity_keys(nil, cache_key .. "::" .. entity)

                if revalidate then
                    local uri, err = redis:hget(entity_keys.main, "uri")
                    if not uri or uri == ngx_null then
                        return nil, err
                    end

                    -- Schedule the background job (immediately). jid is a function of the
                    -- URI for automatic de-duping.
                    _M.put_background_job(redis_params, redis_qless_database, "ledge", "ledge.jobs.revalidate", {
                        uri = uri,
                        entity_keys = entity_keys,
                    }, {
                        jid = ngx_md5("revalidate:" .. uri),
                        tags = { "revalidate" },
                        priority = 5,
                    })
                end

                local res = ledge.expire_keys(
                    redis,
                    ledge.key_chain(nil, cache_key), -- a keychain for this key
                    entity_keys
                )
            end
        end

        local cursor = tonumber(res[1])
        if cursor > 0 then
            -- If we have a valid cursor, recurse to move on.
            return _M.expire_pattern(
                redis,
                redis_slave,
                redis_params,
                redis_qless_database,
                cursor,
                key_chain,
                count,
                job,
                revalidate,
                delete
            )
        end

        return true
    end
end


function _M.put_background_job(redis_params, qless_db, queue, klass, data, options)
    -- Try to connect to a slave for SCAN commands.
    local rc = redis_connector.new()
    redis_params.db = qless_db
    redis_params.role = "master"

    local redis, err = rc:connect(redis_params)

    if not redis then
        return nil, "job-error", "no redis connection provided"
    end

    redis:select(qless_db)
    local q = qless.new({ redis_client = redis })
    -- If we've been specified a jid (i.e. a non random jid), putting this
    -- job will overwrite any existing job with the same jid.
    -- We test for a "running" state, and if so we silently drop this job.
    if options.jid then
        local existing = q.jobs:get(options.jid)

        if existing and existing.state == "running" then
            return nil, "Job with the same jid is currently running"
        end
    end

    -- Put the job
    local res, err = q.queues[queue]:put(klass, data, options)
    if not res then
        ngx.log(ngx.ERR, err)
    end

    redis:set_keepalive()

    return res, err
end


return _M
