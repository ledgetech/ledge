local pcall, tonumber, tostring, pairs =
    pcall, tonumber, tostring, pairs

local tbl_insert = table.insert

local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null
local ngx_time = ngx.time
local ngx_md5 = ngx.md5
local ngx_HTTP_BAD_REQUEST = ngx.HTTP_BAD_REQUEST

local str_find = string.find
local str_sub  = string.sub
local str_len  = string.len

local http = require("resty.http")

local cjson_encode = require("cjson").encode
local cjson_decode = require("cjson").decode

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local put_background_job = require("ledge.background").put_background_job

local key_chain = require("ledge.cache_key").key_chain

local _M = {
    _VERSION = "2.1.4",
}

local repset_len = -(str_len("::repset")+1)


local function create_purge_response(purge_mode, result, qless_jobs)
    local d = {
        purge_mode = purge_mode,
        result = result,
    }
    if qless_jobs then d.qless_jobs = qless_jobs end

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
    for _,key in pairs(key_chain) do
        local _, e = redis:expire(key, new_ttl)
        if e then ngx_log(ngx_ERR, e) end
    end

    -- Reduce TTL on entity if there is one
    if entity_id and entity_id ~= ngx_null then
        storage:set_ttl(entity_id, new_ttl)
    end

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
local function _purge(handler, purge_mode, key_chain)
    local redis = handler.redis
    local storage = handler.storage

    local exists, err = redis:exists(key_chain.main)
    if err then ngx_log(ngx_ERR, err) end

    -- We 404 if we have nothing
    if not exists or exists == ngx_null or exists == 0 then
        return false, "nothing to purge", nil
    end


    -- Delete mode overrides everything else, since you can't revalidate
    if purge_mode == "delete" then
        local res, err = handler:delete_from_cache(key_chain)
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
    local ok, err = expire_keys(redis, storage, key_chain, handler:entity_id(key_chain))

    if not ok and err then
        return nil, err, job

    elseif not ok then
        return false, "already expired", job

    elseif ok then
        return true, "purged", job

    end
end


local function key_chain_from_full_key(root_key, full_key)
    local pos = str_find(full_key, "#")
    if pos == nil then
        return nil
    end

    -- Remove the root_key from the start
    local vary_key = str_sub(full_key, pos+1)
    local vary_spec = {} -- We don't need this

    return key_chain(root_key, vary_key, vary_spec)
end


-- Purges all representatinos of the cache item
local function purge(handler, purge_mode, repset)
    local representations, err = handler.redis:smembers(repset)
    if err then
        return nil, err
    end

    if #representations == 0 then
        return false, "nothing to purge", nil
    end

    local root_key = str_sub(repset, 1, repset_len)

    local res_ok, res_message
    local jobs = {}

    local key_chain
    for _, full_key in ipairs(representations) do
        key_chain = key_chain_from_full_key(root_key, full_key)
        local ok, message, job = _purge(handler, purge_mode, key_chain)

        -- Set the overall response if any representation was purged
        if res_ok == nil or ok == true then
            res_ok = ok
            res_message = message
        end

        tbl_insert(jobs, job)
    end

    -- Clean up vary and repset keys if we're deleting
    if purge_mode == "delete" and res_ok then
       local _, e = handler.redis:del(key_chain.repset, key_chain.vary)
       if e then ngx_log(ngx_ERR, e) end
    end

    return res_ok, res_message, jobs
end
_M.purge = purge


local function purge_in_background(handler, purge_mode)
    local key_chain = handler:cache_key_chain()

    local job, err = put_background_job(
        "ledge_purge",
        "ledge.jobs.purge",
        {
            repset = key_chain.repset,
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
    local res = create_purge_response(purge_mode, "scheduled", {job})
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


local function send_purge_request(uri, purge_mode, headers)
    local uri_parts, err = http:parse_uri(uri)
    if not uri_parts then
        return nil, err
    end

    local scheme, host, port, path = unpack(uri_parts)

    -- TODO: timeouts
    local httpc = http.new()
    local ok, err = httpc:connect(ngx_var.server_addr, port)
    if not ok then
        return nil, "HTTP Connect ("..ngx_var.server_addr..":"..port.."): "..err
    end

    if scheme == "https" then
        local ok, err = httpc:ssl_handshake(nil, host, false)
        if not ok then
            return nil, "SSL Handshake: "..err
        end
    end

    headers = headers or {}
    headers["Host"] = host
    headers["X-Purge"] = purge_mode

    local res, err = httpc:request({
        method = "PURGE",
        path = path,
        headers = headers
    })

    if not res then
        return nil, "HTTP Request: "..err
    end

    local body, err = res:read_body()
    if not body then
        return nil, "HTTP Response: "..err
    end

    local ok, err = httpc:set_keepalive()
    if not ok then ngx_log(ngx_ERR, err) end

    if res.headers["Content-Type"] == "application/json" then
        body = cjson_decode(body)
    else
        return nil, { status = res.status, body = body, headers = res.headers}
    end

    return body
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
        local res, err = send_purge_request(uri, purge_mode, request["headers"])
        if not res then
            res = {["error"] = err}
        elseif type(res) == "table" then
            res["purge_mode"] = nil
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
