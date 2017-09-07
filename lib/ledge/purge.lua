local pcall, tonumber, tostring, pairs =
    pcall, tonumber, tostring, pairs

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null
local ngx_time = ngx.time
local ngx_md5 = ngx.md5

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local cjson_encode = require("cjson").encode
local put_background_job = require("ledge.background").put_background_job


local _M = {
    _VERSION = "2.0.0",
}


local function create_purge_response(purge_mode, result, qless_job)
    local d = {
        purge_mode = purge_mode,
        result = result,
    }
    if qless_job then d.qless_job = qless_job end

    local ok, json = pcall(cjson_encode, d)

    if not ok then
        return nil, json
    else
        return json
    end
end
_M.create_purge_response = create_purge_response


-- Expires the keys in key_chain and reduces the ttl in storage
local function expire_keys(redis, storage, key_chain, entity_id)
    local ttl, err = redis:ttl(key_chain.main)
    if not ttl or ttl == ngx_null or ttl == -1 then
        return nil, "count not determine existing ttl: " .. (err or "")
    end

    if ttl == -2 then
        -- Key doesn't exist, do nothing
        return false, nil
    end

    local expires, err = redis:hget(key_chain.main, "expires")
    expires = tonumber(expires)

    if not expires or expires == ngx_null then
        return nil, "could not determine existing expiry: " .. (err or "")
    end

    local time = ngx_time()

    -- If expires is in the past then this key is stale. Nothing to do here.
    if expires <= time then
        return false, nil
    end

    local ttl_reduction = expires - time
    if ttl_reduction < 0 then ttl_reduction = 0 end
    local new_ttl = ttl - ttl_reduction

    local _, e = redis:multi()
    if e then ngx_log(ngx_ERR, e) end

    -- Set the expires field of the main key to the new time, to control
    -- its validity.
    _, e = redis:hset(key_chain.main, "expires", tostring(time - 1))
    if e then ngx_log(ngx_ERR, e) end

    -- Set new TTLs for all keys in the key chain
    key_chain.fetching_lock = nil -- this looks after itself
    for _,key in pairs(key_chain) do
        local _, e = redis:expire(key, new_ttl)
        if e then ngx_log(ngx_ERR, e) end
    end

    _, e = storage:set_ttl(entity_id, new_ttl)
    if e then ngx_log(ngx_ERR, e) end

    local ok, err = redis:exec() -- luacheck: ignore ok
    if err then
        return nil, err
    else
        return true, nil
    end
end
_M.expire_keys = expire_keys


-- Purges the cache item according to purge_mode which defaults to "invalidate".
-- If there's nothing to do we return false which results in a 404.
-- @param   table   handler instance
-- @param   string  "invalidate" | "delete" | "revalidate
-- @return  boolean success
-- @return  string  message
-- @return  table   qless job (for revalidate only)
local function purge(handler, purge_mode)
    local redis = handler.redis
    local storage = handler.storage
    local key_chain = handler:cache_key_chain()

    local entity_id, err = redis:hget(key_chain.main, "entity")
    if err then ngx_log(ngx_ERR, err) end

    -- We 404 if we have nothing
    if not entity_id or entity_id == ngx_null
        or not storage:exists(entity_id) then

        return false, "nothing to purge", nil
    end

    -- Delete mode overrides everything else, since you can't revalidate
    if purge_mode == "delete" then
        local res, err = handler:delete_from_cache()
        if not res then
            return nil, err, nil
        else
            return true, "deleted", nil
        end
    end

    -- If we're revalidating, fire off the background job
    local job
    if purge_mode == "revalidate" then
        job = handler:revalidate_in_background(false)
    end

    -- Invalidate the keys
    local entity_id = handler:entity_id(key_chain)
    local ok, err = expire_keys(redis, storage, key_chain, entity_id)

    if not ok and err then
        return nil, err

    elseif not ok then
        return false, "already expired", nil

    elseif ok then
        return true, "purged", job

    end
end
_M.purge = purge


local function purge_in_background(handler, purge_mode)
    local key_chain = handler:cache_key_chain()

    local job, err = put_background_job(
        "ledge_purge",
        "ledge.jobs.purge",
        {
            key_chain = key_chain,
            keyspace_scan_count = handler.config.keyspace_scan_count,
            purge_mode = purge_mode,
            storage_driver = handler.config.storage_driver,
            storage_driver_config = handler.config.storage_driver_config,
        },
        {
            jid = ngx_md5("purge:" .. tostring(key_chain.root)),
            tags = { "purge" },
            priority = 5,
        }
    )
    if err then ngx_log(ngx_ERR, err) end

    -- Create a JSON payload for the response
    local res = create_purge_response(purge_mode, "scheduled", job)
    handler.response:set_body(res)

    return true
end
_M.purge_in_background = purge_in_background


return setmetatable(_M, fixed_field_metatable)
