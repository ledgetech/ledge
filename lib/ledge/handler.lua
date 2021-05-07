local setmetatable, tostring, tonumber, pcall, type, ipairs, pairs, next, error =
     setmetatable, tostring, tonumber, pcall, type, ipairs, pairs, next, error

local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_http_version = ngx.req.http_version

local ngx_log = ngx.log
local ngx_WARN = ngx.WARN
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_var = ngx.var
local ngx_null = ngx.null

local ngx_flush = ngx.flush
local ngx_print = ngx.print

local ngx_on_abort = ngx.on_abort
local ngx_md5 = ngx.md5

local ngx_time = ngx.time
local ngx_http_time = ngx.http_time
local ngx_parse_http_time = ngx.parse_http_time

local str_lower = string.lower
local str_len = string.len
local tbl_insert = table.insert
local tbl_concat = table.concat

local esi_capabilities = require("ledge.esi").esi_capabilities

local append_server_port = require("ledge.util").append_server_port

local ledge_cache_key = require("ledge.cache_key")

local req_relative_uri = require("ledge.request").relative_uri
local req_full_uri = require("ledge.request").full_uri

local put_background_job = require("ledge.background").put_background_job
local gc_wait = require("ledge.background").gc_wait

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local ledge = require("ledge")
local http = require("resty.http")
local http_headers = require("resty.http_headers")
local state_machine = require("ledge.state_machine")
local response = require("ledge.response")


local _M = {
    _VERSION = "2.3.0",
}


-- Creates a new handler instance.
--
-- Config defaults are provided in the ledge module, and so instances
-- should always be created with ledge.create_handler(), not directly.
--
-- @param   table   The complete config table
-- @return  table   Handler instance, or nil if no config table is provided
local function new(config, events)
    if not config then return nil, "config table expected" end
    config = setmetatable(config, fixed_field_metatable)

    local self = setmetatable({
    -- public:
        config = config,
        events = events,
        upstream_client = {},

        -- Slots for composed objects
        redis = {},
        redis_subscriber = {},
        storage = {},
        state_machine = {},
        range = {},
        response = {},
        error_response = {},
        esi_processor = {},
        client_validators = {},

        output_buffers_enabled = true,
        esi_scan_enabled = false,
        esi_process_enabled = false,

    -- private:
        _root_key = "",
        _vary_key = ngx_null,  -- empty string is not the same as not set
        _vary_spec = ngx_null, -- empty table is not the same as not set
        _cache_key_chain = {},
        _publish_key = "",

    }, get_fixed_field_metatable_proxy(_M))

    return self
end
_M.new = new


local function run(self)
    -- Instantiate state machine
    local sm = state_machine.new(self)
    self.state_machine = sm

    -- Install the client abort handler
    local ok, err = ngx_on_abort(function()
        return self.state_machine:e "aborted"
    end)

    if not ok then
       ngx_log(ngx_WARN, "on_abort handler could not be set: " .. err)
    end

    -- Create Redis connection
    local redis, err = ledge.create_redis_connection()
    if not redis then
        return nil, "could not connect to redis, " .. tostring(err)
    else
        self.redis = redis
    end

    -- Create storage connection
    local config = self.config
    local storage, err = ledge.create_storage_connection(
        config.storage_driver,
        config.storage_driver_config
    )
    if not storage then
        return nil, "could not connect to storage, " .. tostring(err)
    else
        self.storage = storage
    end

    return sm:e "init"
end
_M.run = run


-- Bind a user callback to an event
--
-- Callbacks will be called in the order they are bound
--
-- @param   table           self
-- @param   string          event name
-- @param   function        callback
-- @return  bool, string    success, error
local function bind(self, event, callback)
    local ev = self.events[event]
    if not ev then
        local err = "no such event: " .. tostring(event)
        ngx_log(ngx_ERR, err)
        return nil, err
    else
        tbl_insert(ev, callback)
    end
    return true, nil
end
_M.bind = bind


-- Calls any registered callbacks for event, in the order they were bound
-- Hard errors if event is not specified in self.events
local function emit(self, event, ...)
    local ev = self.events[event]
    if not ev then
        error("attempt to emit non existent event: " .. tostring(event), 2)
    end

    for _, handler in ipairs(ev) do
        if type(handler) == "function" then
            local ok, err = pcall(handler, ...)
            if not ok then
                ngx_log(ngx_ERR,
                    "error in user callback for '", event, "': ", err)
            end
        end
    end

    return true
end
_M.emit = emit


function _M.entity_id(self, key_chain)
    if not key_chain or not key_chain.main then return nil end

    local entity_id, err = self.redis:hget(key_chain.main, "entity")
    if not entity_id or entity_id == ngx_null then
        return nil, err
    end

    return entity_id
end


local function root_key(self)
    if self._root_key == "" then
        self._root_key = ledge_cache_key.generate_root_key(
                self.config.cache_key_spec,
                self.config.max_uri_args
            )
    end

    return self._root_key
end
_M.root_key = root_key


local function vary_spec(self, root_key)
    if self._vary_spec == ngx_null then
        local vary_spec, err = ledge_cache_key.read_vary_spec(
                self.redis,
                root_key
            )
        if not vary_spec then
            ngx_log(ngx_ERR, "Failed to read vary spec: ", err)
            return false
        end
        self._vary_spec = vary_spec
    end

    return self._vary_spec
end
_M.vary_spec = vary_spec


local function create_vary_key_callback(self)
    return function(vary_key)
            -- TODO: gunzip?
            emit(self, "before_vary_selection", vary_key)
        end
end
_M.create_vary_key_callback = create_vary_key_callback


local function vary_key(self, vary_spec)
    if self._vary_key == ngx_null then
        self._vary_key = ledge_cache_key.generate_vary_key(
                vary_spec,
                create_vary_key_callback(self)
            )
    end

    return self._vary_key
end
_M.vary_key = vary_key


local function cache_key_chain(self)
    if not next(self._cache_key_chain) then
        if not self.redis or not next(self.redis) then
            ngx_log(ngx_ERR, "Cannot get cache key without a redis connection")
            return nil
        end

        local rk = root_key(self)

        local vs = vary_spec(self, rk)

        local vk = vary_key(self, vs)

        local chain, err = ledge_cache_key.key_chain(rk, vk, vs)

        if not chain then
            return nil, err
        end

        self._cache_key_chain = chain
    end

    return self._cache_key_chain
end
_M.cache_key_chain = cache_key_chain


local function reset_cache_key(self)
    self._root_key = ""
    self._vary_key = ngx_null
    self._vary_spec = ngx_null
    self._cache_key_chain = {}
end
_M.reset_cache_key = reset_cache_key


local function set_vary_spec(self, vary_spec)
    reset_cache_key(self)
    if vary_spec then
        self._vary_spec = vary_spec
    end
end
_M.set_vary_spec = set_vary_spec


local function read_from_cache(self)
    local res, err = response.new(self)
    if not res then return nil, err end

    local ok, err = res:read()
    if err then
        -- Error, abort request
        ngx_log(ngx_ERR, "could not read response: ", err)
        return self.state_machine:e "http_internal_server_error"
    end

    if not ok then
        return {} -- MISS
    end

    if res.size > 0 then
        local storage = self.storage

        -- Check storage has the entity, if not presume it has been evitcted
        -- and clean up
        if not storage:exists(res.entity_id) then
            local config = self.config
            put_background_job(
                "ledge_gc",
                "ledge.jobs.collect_entity",
                {
                    entity_id = res.entity_id,
                    storage_driver = config.storage_driver,
                    storage_driver_config = config.storage_driver_config,
                },
                {
                    delay = gc_wait(
                        res.size,
                        config.minimum_old_entity_download_rate
                    ),
                    tags = { "collect_entity" },
                    priority = 10,
                }
            )
            return {} -- MISS
        end

        res:filter_body_reader("cache_body_reader", storage:get_reader(res))
    end

    emit(self, "after_cache_read", res)
    return res
end
_M.read_from_cache = read_from_cache


-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
local hop_by_hop_headers = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
    ["content-length"]      = true,  -- Not strictly hop-by-hop, but we
    -- set dynamically downstream.
}


-- Fetches a resource from the origin server.
local function fetch_from_origin(self)
    local res, err = response.new(self)
    if not res then return nil, err end

    local method = ngx['HTTP_' .. ngx_req_get_method()]
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    emit(self, "before_upstream_connect", self)

    local config = self.config

    if not next(self.upstream_client) then
        local httpc = http.new()
        httpc:set_timeouts(
            config.upstream_connect_timeout,
            config.upstream_send_timeout,
            config.upstream_read_timeout
        )

        local port = tonumber(config.upstream_port)
        local ok, err
        if port then
            ok, err = httpc:connect(config.upstream_host, port)
        else
            ok, err = httpc:connect(config.upstream_host)
        end

        if not ok then
            ngx_log(ngx_ERR, "upstream connection failed: ", err)
            if err == "timeout" then
                res.status = 524 -- upstream server timeout
            else
                res.status = 503
            end
            httpc:close()
            return res
        end

        if config.upstream_use_ssl == true then
            -- treat an empty ("") ssl_server_name as nil
            local ssl_server_name = config.upstream_ssl_server_name
            if type(ssl_server_name) ~= "string" or
                str_len(ssl_server_name) == 0 then

                ssl_server_name = nil
            end

            local ok, err = httpc:ssl_handshake(
                false,
                ssl_server_name,
                config.upstream_ssl_verify
            )

            if not ok then
                ngx_log(ngx_ERR, "ssl handshake failed: ", err)
                res.status = 525 -- SSL Handshake Failed
                return res
            end
        end
        self.upstream_client = httpc
    end

    local upstream_client = self.upstream_client

    -- Case insensitve headers so that we can safely manipulate them
    local headers = http_headers.new()
    for k,v in pairs(ngx_req_get_headers()) do
        headers[k] = v
    end

    -- Advertise ESI surrogate capabilities
    if config.esi_enabled then
        local capability_entry = self.config.visible_hostname  .. '="'
            .. esi_capabilities() .. '"'

        local sc = headers["Surrogate-Capability"]

        if not sc then
            headers["Surrogate-Capability"] = capability_entry
        else
            headers["Surrogate-Capability"] = sc .. ", " .. capability_entry
        end
    end

    local client_body_reader, err =
        upstream_client:get_client_body_reader(config.buffer_size)

    if err then
        ngx_log(ngx_ERR, "error getting client body reader: ", err)
    end

    local req_params = {
        method = ngx_req_get_method(),
        path = req_relative_uri(),
        body = client_body_reader,
        headers = headers,
    }

    -- allow request params to be customised
    emit(self, "before_upstream_request", req_params)

    local origin, err = upstream_client:request(req_params)

    if not origin then
        ngx_log(ngx_ERR, err)
        res.status = 524
        upstream_client:close()
        return res
    end

    res.status = origin.status

    -- Merge end-to-end headers
    local hop_by_hop_headers = hop_by_hop_headers
    for k,v in pairs(origin.headers) do
        if not hop_by_hop_headers[str_lower(k)] then
            res.header[k] = v
        end
    end

    -- May well be nil (we set to false if that's the case), but if present
    -- we bail on saving large bodies to memory nice and early.
    res.length = tonumber(origin.headers["Content-Length"]) or false

    res.has_body = origin.has_body
    res:filter_body_reader(
        "upstream_body_reader",
        origin.body_reader
    )

    if res.status < 500 then
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be
        -- assigned one by the recipient if the message will be cached by that
        -- recipient
        if type(res.header["Date"]) ~= "string" or
            not ngx_parse_http_time(res.header["Date"]) then

            ngx_log(ngx_WARN,
                "Missing or invalid Date header from upstream, generating locally"
            )
            res.header["Date"] = ngx_http_time(ngx_time())
        end
    end

    -- A nice opportunity for post-fetch / pre-save work.
    emit(self, "after_upstream_request", res)

    return res
end
_M.fetch_from_origin = fetch_from_origin


-- Returns data required to perform a background revalidation for this current
-- request, as two tables; reval_params and reval_headers.
local function revalidation_data(self)
    -- Everything that a headless revalidation job would need to connect
    local config = self.config
    local reval_params = {
        server_addr = ngx_var.server_addr,
        server_port = ngx_var.server_port,
        scheme = ngx_var.scheme,
        uri = ngx_var.request_uri,
        connect_timeout = config.upstream_connect_timeout,
        send_timeout = config.upstream_send_timeout,
        read_timeout = config.upstream_read_timeout,
        keepalive_timeout = config.upstream_keepalive_timeout,
        keepalive_poolsize = config.upstream_keepalive_poolsize,
    }

    local h = ngx_req_get_headers()

    -- By default we pass through Host, and Authorization and Cookie headers
    -- if present.
    local reval_headers = {
        host = h["Host"],
    }

    if h["Authorization"] then
        reval_headers["Authorization"] = h["Authorization"]
    end
    if h["Cookie"] then
        reval_headers["Cookie"] = h["Cookie"]
    end

    emit(self, "before_save_revalidation_data", reval_params, reval_headers)

    return reval_params, reval_headers
end


local function revalidate_in_background(self, key_chain, update_revalidation_data)
    local redis = self.redis

    -- Revalidation data is updated if this is a proper request, but not if
    -- it's a purge request.
    if update_revalidation_data then
        local reval_params, reval_headers = revalidation_data(self)

        local ttl, err = redis:ttl(key_chain.reval_params)
        if not ttl or ttl == ngx_null or ttl < 0 then
            if err then ngx_log(ngx_ERR, err) end
            ngx_log(ngx_INFO,
                "Could not determine expiry for revalidation params. " ..
                "Will fallback to 3600 seconds."
            )
            -- Arbitrarily expire these revalidation parameters in an hour.
            ttl = 3600
        end

        -- Delete and update reval request headers
        local _, e
        _, e = redis:multi()
        if e then ngx_log(ngx_ERR, e) end
        _, e = redis:del(key_chain.reval_params)
        if e then ngx_log(ngx_ERR, e) end
        _, e = redis:hmset(key_chain.reval_params, reval_params)
        if e then ngx_log(ngx_ERR, e) end
        _, e = redis:expire(key_chain.reval_params, ttl)
        if e then ngx_log(ngx_ERR, e) end

        _, e = redis:del(key_chain.reval_req_headers)
        if e then ngx_log(ngx_ERR, e) end
        _, e = redis:hmset(key_chain.reval_req_headers, reval_headers)
        if e then ngx_log(ngx_ERR, e) end
        _, e = redis:expire(key_chain.reval_req_headers, ttl)
        if e then ngx_log(ngx_ERR, e) end

        local res, err = redis:exec()
        if not res or res == ngx_null then
            ngx_log(ngx_ERR, "Could not update revalidation params: ", err)
        end
    end

    local uri, err = redis:hget(key_chain.main, "uri")
    if not uri or uri == ngx_null then
        if err then
            ngx_log(ngx_ERR, "Failed to get main key while revalidating: ", err)
        else
            ngx_log(ngx_WARN,
                "Cache key has no 'uri' field, aborting revalidation"
            )
        end
        return nil
    end

    -- Schedule the background job (immediately). jid is a function of the
    -- URI for automatic de-duping.
    return put_background_job(
        "ledge_revalidate",
        "ledge.jobs.revalidate",
        { key_chain = key_chain },
        {
            jid = ngx_md5("revalidate:" .. uri),
            tags = { "revalidate" },
            priority = 4,
        }
    )
end
_M.revalidate_in_background = revalidate_in_background


-- Starts a "revalidation" job but maybe for brand new cache. We pass the
-- current request's revalidation data through so that the job has meaninful
-- parameters to work with (rather than using stored metadata).
local function fetch_in_background(self)
    local key_chain = cache_key_chain(self)
    local reval_params, reval_headers = revalidation_data(self)
    return put_background_job(
        "ledge_revalidate",
        "ledge.jobs.revalidate",
        {
            key_chain = key_chain,
            reval_params = reval_params,
            reval_headers = reval_headers,
        },
        {
            jid = ngx_md5("revalidate:" .. req_full_uri()),
            tags = { "revalidate" },
            priority = 4,
        }
    )
end
_M.fetch_in_background = fetch_in_background


local function save_to_cache(self, res)
    if not res then return nil, "no response to save" end
    emit(self, "before_save", res)

    -- Length is only set if there was a Content-Length header
    local length = res.length
    local storage = self.storage
    local max_size = storage:get_max_size()
    if length and length > max_size then
        -- We'll carry on serving, just not saving.
        return nil, "advertised length is greated than storage max size"
    end


    -- Watch the main key pointer. We abort the transaction if another request
    -- updates this key before we finish.
    local key_chain = cache_key_chain(self)
    local redis = self.redis
    redis:watch(key_chain.main)

    local repset_ttl = redis:ttl(key_chain.repset)

    -- We'll need to mark the old entity for expiration shortly, as reads
    -- could still be in progress. We need to know the previous entity keys
    -- and the size.
    local previous_entity_id = self:entity_id(key_chain)

    local previous_entity_size, err, gc_job_spec
    if previous_entity_id then
        previous_entity_size, err = redis:hget(key_chain.main, "size")
        if previous_entity_size == ngx_null then
            previous_entity_id = nil
            if err then
                ngx_log(ngx_ERR, err)
            end
        end

        -- Define GC job here, used later if required
        gc_job_spec = {
            "ledge_gc",
            "ledge.jobs.collect_entity",
            {
                entity_id = previous_entity_id,
                storage_driver = self.config.storage_driver,
                storage_driver_config = self.config.storage_driver_config,
            },
            {
                delay = gc_wait(
                    previous_entity_size,
                    self.config.minimum_old_entity_download_rate
                ),
                tags = { "collect_entity" },
                priority = 10,
            }
        }
    end

    -- Start the transaction
    local ok, err = redis:multi()
    if not ok then ngx_log(ngx_ERR, err) end

    if previous_entity_id then
        local ok, err = redis:srem(key_chain.entities, previous_entity_id)
        if not ok then ngx_log(ngx_ERR, err) end
    end

    res.uri = req_full_uri()

    local keep_cache_for = self.config.keep_cache_for
    local ok, err = res:save(keep_cache_for)
    if not ok then ngx_log(ngx_ERR, err) end

    -- Set revalidation parameters from this request
    local reval_params, reval_headers = revalidation_data(self)

    local _, err = redis:del(key_chain.reval_params)
    if err then ngx_log(ngx_ERR, err) end
    _, err = redis:hmset(key_chain.reval_params, reval_params)
    if err then ngx_log(ngx_ERR, err) end

    _, err = redis:del(key_chain.reval_req_headers)
    if err then ngx_log(ngx_ERR, err) end
    _, err = redis:hmset(key_chain.reval_req_headers, reval_headers)
    if err then ngx_log(ngx_ERR, err) end

    local expiry = res:ttl() + keep_cache_for
    redis:expire(key_chain.reval_params, expiry)
    redis:expire(key_chain.reval_req_headers, expiry)


    -- repset and vary TTL should be the same as the longest living represenation
    if repset_ttl < expiry then
        repset_ttl = expiry
    end

    -- Save updates to cache key
    ledge_cache_key.save_key_chain(redis, key_chain, repset_ttl)

    -- If we have a body, we need to attach the storage writer
    -- NOTE: res.has_body is false for known bodyless repsonse types
    -- (e.g. HEAD) but may be true and of zero length (commonly 301 etc).
    if res.has_body then

        -- Storage callback for write success
        local function onsuccess(bytes_written)
            -- Update size in metadata
            local ok, e = redis:hset(key_chain.main, "size", bytes_written)
            if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end

            if bytes_written == 0 then
                -- Remove the entity as it wont exist
                ok, e = redis:srem(key_chain.entities, res.entity_id)
                if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end

                ok, e = redis:hdel(key_chain.main, "entity")
                if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
            end

            ok, e = redis:exec()
            if not ok or ok == ngx_null then
                if e then
                    ngx_log(ngx_ERR, "failed to complete transaction: ", e)
                else
                    -- Transaction likely failed due to watch on main key
                    -- Tell storage to clean up too
                    ok, e = storage:delete(res.entity_id) -- luacheck: ignore ok
                    if e then
                        ngx_log(ngx_ERR, "failed to cleanup storage: ", e)
                    end
                end
            elseif previous_entity_id then
                -- Everything has completed and we have an old entity
                -- Schedule GC to clean it up
                put_background_job(unpack(gc_job_spec))
            end
        end

        -- Storage callback for write failure. We roll back our transaction.
        local function onfailure(reason)
            ngx_log(ngx_ERR, "storage failed to write: ", reason)

            local ok, e = redis:discard()
            if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
        end

        -- Attach storage writer
        local ok, writer = pcall(storage.get_writer, storage,
            res,
            keep_cache_for,
            onsuccess,
            onfailure
        )
        if not ok then
            ngx_log(ngx_ERR, writer)
        else
            res:filter_body_reader("cache_body_writer", writer)
        end

    else
        -- No body and thus no storage filter
        -- We can run our transaction immediately
        local ok, e = redis:exec()
        if not ok or ok == ngx_null then
            ngx_log(ngx_ERR, "failed to complete transaction: ", e)
        elseif previous_entity_id then
            -- Everything has completed and we have an old entity
            -- Schedule GC to clean it up
            put_background_job(unpack(gc_job_spec))
        end
    end
    return true
end
_M.save_to_cache = save_to_cache


local function delete_from_cache(self, key_chain)
    local redis = self.redis

    -- Get entity_id if not already provided
    local entity_id = self:entity_id(key_chain)

    -- Schedule entity collection
    if entity_id then
        local config = self.config
        local size = redis:hget(key_chain.main, "size")
        put_background_job(
            "ledge_gc",
            "ledge.jobs.collect_entity",
            {
                entity_id = entity_id,
                storage_driver = config.storage_driver,
                storage_driver_config = config.storage_driver_config,
            },
            {
                delay = gc_wait(
                    size,
                    config.minimum_old_entity_download_rate
                ),
                tags = { "collect_entity" },
                priority = 10,
            }
        )
    end

    -- Remove this representation from the repset
    redis:srem(key_chain.repset, key_chain.full)

    -- Delete everything in the keychain
    local keys = {}
    for _, v in pairs(key_chain) do
        tbl_insert(keys, v)
    end

    -- If there are no more entries in the repset clean up the vary key too
    local exists = redis:exists(key_chain.repset)
    if exists == 0 then
        tbl_insert(keys, key_chain.vary)
    end

    return redis:del(unpack(keys))
end
_M.delete_from_cache = delete_from_cache


-- Resumes the reader coroutine and prints the data yielded. This could be
-- via a cache read, or a save via a fetch... the interface is uniform.
local function serve_body(self, res, buffer_size)
    local buffered = 0
    local reader = res.body_reader
    local can_flush = ngx_req_http_version() >= 1.1

    repeat
        local chunk, err = reader(buffer_size)
        if err then ngx_log(ngx_ERR, err) end
        if chunk and self.output_buffers_enabled then
            local ok, err = ngx_print(chunk)
            if not ok then ngx_log(ngx_INFO, err) end

            -- Flush each full buffer, if we can
            buffered = buffered + #chunk
            if can_flush and buffered >= buffer_size then
                local ok, err = ngx_flush(true)
                if not ok then ngx_log(ngx_INFO, err) end

                buffered = 0
            end
        end

    until not chunk
end


local function serve(self)
    if not ngx.headers_sent then
        local res = self.response
        local name = append_server_port(self.config.visible_hostname)

        -- Via header
        local via = "1.1 " .. name
        if self.config.advertise_ledge then
            via = via .. " (ledge/" .. _M._VERSION .. ")"
        end

        -- Append upstream Via
        local res_via = res.header["Via"]
        if (res_via ~= nil) then
            -- Fix multiple upstream Via headers into list form
            if (type(res_via) == "table") then
                res.header["Via"] = via .. ", " .. tbl_concat(res_via, ", ")
            else
                res.header["Via"] = via .. ", " .. res_via
            end
        else
            res.header["Via"] = via
        end

        -- X-Cache header
        -- Don't set if this isn't a cacheable response. Set to MISS is we
        -- fetched.
        local state_history = self.state_machine.state_history
        local event_history = self.state_machine.event_history

        if not event_history["response_not_cacheable"] then
            local x_cache = "HIT from " .. name
            if not event_history["can_serve_disconnected"]
                and not event_history["can_serve_stale"]
                and state_history["fetching"] then

                x_cache = "MISS from " .. name
            end

            local res_x_cache = res.header["X-Cache"]

            if res_x_cache ~= nil then
                res.header["X-Cache"] = x_cache .. ", " .. res_x_cache
            else
                res.header["X-Cache"] = x_cache
            end
        end

        emit(self, "before_serve", res)

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        if res.body_reader and ngx_req_get_method() ~= "HEAD" then
            local buffer_size = self.config.buffer_size
            serve_body(self, res, buffer_size)
        end

        ngx.eof()
    end
end
_M.serve = serve


local function add_warning(self, code)
    return self.response:add_warning(
            code,
            append_server_port(self.config.visible_hostname)
        )
end
_M.add_warning = add_warning


return setmetatable(_M, fixed_field_metatable)
