local pcall, tonumber, tostring, pairs =
    pcall, tonumber, tostring, pairs
local str_byte = string.byte
local str_find = string.find

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null
local ngx_time = ngx.time
local ngx_md5 = ngx.md5
local ngx_HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST

local http = require("resty.http")

local cjson_encode = require("cjson").encode
local cjson_decode = require("cjson").decode

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local put_background_job = require("ledge.background").put_background_job

local generate_cache_key = require("ledge.cache_key").generate_cache_key
local key_chain = require("ledge.cache_key").key_chain


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
-- @param   table   key_chain to purge
-- @return  boolean success
-- @return  string  message
-- @return  table   qless job (for revalidate only)
local function purge(handler, purge_mode, key_chain)
    local redis = handler.redis
    local storage = handler.storage

    local entity_id, err = handler:entity_id(key_chain)
    if err then ngx_log(ngx_ERR, err) end

    -- We 404 if we have nothing
    if not entity_id or entity_id == ngx_null
        or not storage:exists(entity_id) then

        return false, "nothing to purge", nil
    end

    -- Delete mode overrides everything else, since you can't revalidate
    if purge_mode == "delete" then
        local res, err = handler:delete_from_cache(key_chain, entity_id)
        if not res then
            return nil, err, nil
        else
            return true, "deleted", nil
        end
    end

    -- If we're revalidating, fire off the background job
    local job
    if purge_mode == "revalidate" then
        job = handler:revalidate_in_background(key_chain, false)
    end

    -- Invalidate the keys
    local ok, err = expire_keys(redis, storage, key_chain, entity_id)

    if not ok and err then
        return nil, err, job

    elseif not ok then
        return false, "already expired", job

    elseif ok then
        return true, "purged", job

    end
end
_M.purge = purge


local function schedule_purge_job(handler, purge_mode, key_chain)
    return put_background_job(
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
end


local function purge_in_background(handler, purge_mode)
    local job, err = schedule_purge_job(handler, purge_mode, handler:cache_key_chain())
    if err then ngx_log(ngx_ERR, err) end

    -- Create a JSON payload for the response
    local res = create_purge_response(purge_mode, "scheduled", job)
    handler.response:set_body(res)

    return true
end
_M.purge_in_background = purge_in_background


local function parse_json_req()
    ngx.req.read_body()
    local body, err = ngx.req.get_body_data()
    if not body then
        return nil, "Could not read request body: " .. tostring(err)
    end

    local ok, req = pcall(cjson_decode, body)
    if not ok then
        return nil, "Could not parse request body: " .. tostring(req)
    end

    return req
end


local function validate_api_request(req)
    local uris = req["uris"]
    if not uris then
        return false, "No URIs provided"
    end

    if type(uris) ~= "table" then
        return false, "Field 'uris' must be an array"
    end

    if #uris == 0 then
        return false, "No URIs provided"
    end

    local mode = req["purge_mode"]
    if mode and not (
        mode    == "invalidate"
        or mode == "revalidate"
        or mode == "delete"
    ) then
        return false, "Invalid purge_mode"
    end

    return true
end


local function key_chain_from_uri(handler, uri, headers)
    local parsed, err = http:parse_uri(uri, false)
    if not parsed then
        return nil, "URI Parse Error: "..err
    end

    local args = parsed[5]
    local uri  = parsed[4]

    if args and args ~= "" then
        -- Query string is in the URI
        -- Check if we're purging /some/uri?*
        if args ~= "*" then
            args = ngx.decode_args(args, handler.config.max_uri_args or 100)
        end
    elseif str_byte(uri, -1) == 42 then
        -- Purging /some/uri/* with no query string specified.
        -- Default args to *
        args = "*"
    else
        args = nil
    end

    --local scheme, host, port, path, query = unpack(parsed_uri)
    local vars = {
        ["scheme"] = parsed[1],
        ["host"] = parsed[2],
        ["port"] = parsed[3],
        ["uri"] = uri,
        ["args"] = args,
        ["headers"] = headers,
    }

    -- Generate new cache_key
    local cache_key = generate_cache_key(
        handler.config.cache_key_spec,
        handler.config.max_uri_args,
        vars
    )
    ngx.log(ngx.DEBUG, "CACHE KEY: ", cache_key)
    return key_chain(cache_key)
end


-- Run the JSON PURGE API.
-- Accepts various inputs from a JSON request body and processes purges
-- Return true on success or false on error
local function purge_api(handler)
    local response = handler.response

    local request, err = parse_json_req()
    if not request then
        response.status = ngx_HTTP_BAD_REQUEST
        response:set_body(cjson_encode({["error"] = err}))
        return false
    end

    local ok, err = validate_api_request(request)
    if not ok then
        response.status = ngx_HTTP_BAD_REQUEST
        response:set_body(cjson_encode({["error"] = err}))
        return false
    end

    local purge_mode = request["purge_mode"] or "invalidate" -- Default to invalidating
    local api_results = {}

    local uris = request["uris"]
    for _, uri in ipairs(uris) do
        local res = {}
        local key_chain, err = key_chain_from_uri(handler, uri, request["headers"])

        if not key_chain then
            res["error"] = err

        else
            if str_find(uri, "*", 1, true) ~= nil then
                -- Schedule wildcard purge job
                local job, err = schedule_purge_job(handler, purge_mode, key_chain)
                if err then
                    res["error"] = "error"
                else
                    res["result"] = "scheduled"
                    res["qless_job"] = job
                end

            else
                -- Purge the URI now
                local ok, purge_result, job = purge(handler, purge_mode, key_chain)
                res["qless_job"] = job
                if ok == nil and purge_result then
                    res["error"] = purge_result
                else
                    res["result"] = purge_result
                end

            end
        end

        api_results[uri] = res
    end

    local api_response, err = create_purge_response(purge_mode, api_results)
    if not api_response then
        handler.set:body(cjson_encode({["error"] = "JSON Response Error: "..tostring(err)}))
        return false
    end

    handler.response:set_body(api_response)
    return true
end
_M.purge_api = purge_api


return setmetatable(_M, fixed_field_metatable)
