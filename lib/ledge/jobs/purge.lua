local redis_connector = require "resty.redis.connector"
local ledge = require "ledge.ledge"
local qless = require "resty.qless"

local ipairs, tonumber = ipairs, tonumber
local str_len = string.len
local str_sub = string.sub
local ngx_null = ngx.null
local ngx_md5 = ngx.md5

local _M = {
    _VERSION = '1.26',
}


-- Scans the keyspace for keys which match, and expires them. We do this against
-- the slave Redis instance if available.
function _M.perform(job)
    -- Try to connect to a slave for SCAN commands.
    local rc = redis_connector.new()
    rc:set_connect_timeout(job.redis_connection_options.connect_timeout)
    rc:set_read_timeout(job.redis_connection_options.read_timeout)
    job.redis_params.role = "slave"

    job.redis_slave = rc:connect(job.redis_params)
    if not job.redis_slave then job.redis_slave = job.redis end -- in case there is no slave
    job.redis_params.role = "master" -- switch params back to master

    if not job.redis then
        return nil, "job-error", "no redis connection provided"
    end

    -- This runs recursively using the SCAN cursor, until the entire keyspace
    -- has been scanned.
    local res, err = _M.expire_pattern(0, job)

    if res ~= nil then
        return true, nil
    else
        return nil, "redis-error", err
    end
end


-- Scans the keyspace based on a pattern (asterisk) present in the main key,
-- including the ::key suffix to denote the main key entry.
-- (i.e. one per entry)
function _M.expire_pattern(cursor, job)
    local res, err = job.redis_slave:scan(
        cursor,
        "MATCH", job.data.key_chain.key,
        "COUNT", job.data.keyspace_scan_count
    )

    if job:ttl() < 10 then
        if not job:heartbeat() then
            return false, "Failed to heartbeat job"
        end
    end

    if not res or res == ngx_null then
        return nil, "SCAN error: "..tostring(err)
    else
        for _,key in ipairs(res[2]) do
            local entity = job.redis:get(key)
            if entity and entity ~= ngx_null then
                -- Remove the ::key part to give the cache_key without a suffix
                local cache_key = str_sub(key, 1, -(str_len("::key") + 1))
                -- the entity keys for the live entity
                local entity_keys = ledge.entity_keys(cache_key .. "::" .. entity)

                if job.data.purge_mode == "delete" then
                    local k_chain = ledge.key_chain(nil, cache_key)
                    -- hard delete, not just expire
                    ledge.delete(job.redis, k_chain)
                    ledge.delete(job.redis, entity_keys)

                elseif job.data.purge_mode == "revalidate" then
                    local uri, err = job.redis:hget(entity_keys.main, "uri")
                    if not uri or uri == ngx_null then
                        -- If main key is missing or (somehow) the uri field is missing
                        -- Log error but continue processing keys
                        -- TODO: schedule gc cleanup here?
                        if not err then
                            ngx.log(ngx.ERR, "Entity broken: ", cache_key, "::", entity)
                        else
                            ngx.log(ngx.ERR, "Redis Error: ", err)
                        end
                    else
                        -- Schedule the background job (immediately). jid is a function of the
                        -- URI for automatic de-duping.
                        _M.put_background_job(
                            job.redis_params,
                            job.redis_qless_database,
                            "ledge_revalidate",
                            "ledge.jobs.revalidate", {
                                uri = uri,
                                entity_keys = entity_keys,
                            }, {
                                jid = ngx_md5("revalidate:" .. uri),
                                tags = { "revalidate" },
                                priority = 3,
                            }
                        )
                    end
                end

                local res = ledge.expire_keys(
                    job.redis,
                    ledge.key_chain(nil, cache_key), -- a keychain for this key
                    entity_keys
                )
            end -- if not entity
        end -- loop

        local cursor = tonumber(res[1])
        if cursor > 0 then
            -- If we have a valid cursor, recurse to move on.
            return _M.expire_pattern(cursor, job)
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
