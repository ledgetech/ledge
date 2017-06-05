local http = require("resty.http")
local http_headers = require("resty.http_headers")
local qless = require("resty.qless")
local zlib = require("ffi-zlib")

local ledge = require("ledge")
local h_util = require("ledge.header_util")
local state_machine = require("ledge.state_machine")
local response = require("ledge.response")
local esi = require("ledge.esi")

local setmetatable = setmetatable

local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_req_http_version = ngx.req.http_version

local ngx_time = ngx.time
local ngx_http_time = ngx.http_time
local ngx_parse_http_time = ngx.parse_http_time

local ngx_re_find = ngx.re.find
local ngx_re_sub = ngx.re.sub
local ngx_re_gsub = ngx.re.gsub

local ngx_print = ngx.print
local ngx_flush = ngx.flush
local ngx_on_abort = ngx.on_abort

local ngx_log = ngx.log
local ngx_INFO = ngx.INFO
local ngx_WARN = ngx.WARN
local ngx_ERR = ngx.ERR

local ngx_null = ngx.null
local ngx_var = ngx.var

local ngx_md5 = ngx.md5

local str_lower = string.lower

local math_min = math.min
local math_ceil = math.ceil

local tbl_insert = table.insert
local tbl_concat = table.concat

local co_yield = coroutine.yield
local co_wrap = require("ledge.util").coroutine.wrap

local cjson_encode = require("cjson").encode
local cjson_decode = require("cjson").decode

local req_purge_mode = require("ledge.request").purge_mode
local req_relative_uri = require("ledge.request").relative_uri
local req_full_uri = require("ledge.request").full_uri
local req_visible_hostname = require("ledge.request").visible_hostname

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local WARNINGS = {
    ["110"] = "Response is stale",
    ["214"] = "Transformation applied",
    ["112"] = "Disconnected Operation",
}


local _M = {
    _VERSION = "1.28.3",
}


-- Creates a new handler instance.
--
-- Config defaults are provided in the ledge module, and so instances
-- should always be created with ledge.create_handler(), not directly.
--
-- @param   table   The complete config table
-- @return  table   Handler instance, or nil if no config table is provided
local function new(config)
    if not config then return nil, "config table expected" end
    config = setmetatable(config, fixed_field_metatable)

    local self = setmetatable({
        config = config,

        -- Slots for composed objects
        redis = {},
        storage = {},
        state_machine = {},
        range = {},
        response = {},
        error_response = {},
        esi_processor = {},

        -- TODO These fields were in ctx, now in self, collided with function
        -- names.
        t_cache_key = "",
        t_cache_key_chain = true, -- hmm

        client_validators = {},

        -- Events not listed here cannot be bound / emitted
        events = {
            after_cache_read = {},
            before_upstream_request = {},
            after_upstream_request = {},
            before_save = {},
            before_save_revalidation_data = {},
            before_serve = {},
            before_esi_include_request = {},
        },

        output_buffers_enabled = true,
        esi_scan_disabled = true,
        esi_scan_enabled = false, -- TODO: errrr, both?
        esi_process_enabled = false,

    }, get_fixed_field_metatable_proxy(_M))

    return self
end
_M.new = new


local function run(self)
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

    -- Instantiate state machine
    local sm = state_machine.new(self)
    self.state_machine = sm

    return sm:e "init"
end
_M.run = run


-- DEPRECATED
-- Use handler.config directly
local function config_get(self, k)
    return self.config[k]
end
_M.config_get = config_get



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
        tbl_insert(self.events[event], callback)
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
end




-- Close and optionally keepalive the redis connection
-- TODO either in state machine or something
function _M.redis_close(self)
    return ledge.close_redis_connection(self.redis)
end



-- TODO deprecated. Err response needs its own space
function _M.set_response(self, res, name)
  --  local name = name or "response"
  --  self.name] = res
    if not res then
        self.response = {}
    else
        self.response = res
    end
end


-- TODO deprecated. Err response needs its own space
function _M.get_response(self, name)
    return self.response
  --  local name = name or "response"
  --  return self.name]
end


-- Generates or returns the cache key. The default spec is:
-- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
function _M.cache_key(self)
    if self.t_cache_key == "" then

        -- If there is is a wildcard PURGE request with an asterisk placed
        -- at the end of the path, and we have no args, use * as the args.
        local args_default = ""
        if ngx_req_get_method() == "PURGE" then
            if ngx_re_find(ngx_var.request_uri, "\\*$", "soj") then
                args_default = "*"
            end
        end

        -- If args is manipulated before us, it may be a zero length string.
        local args = ngx_var.args
        if not args or args == "" then
            args = args_default
        end

        --local key_spec = self:config_get("cache_key_spec") or {
        local key_spec = {
            ngx_var.scheme,
            ngx_var.host,
            ngx_var.uri,
            args,
        }
        tbl_insert(key_spec, 1, "cache")
        tbl_insert(key_spec, 1, "ledge")
        self.t_cache_key = tbl_concat(key_spec, ":")
    end
    return self.t_cache_key
end


-- Returns the key chain for all cache keys, except the body entity
function _M.key_chain(self, cache_key)
    return setmetatable({
        -- hash: cache key metadata
        main = cache_key .. "::main",

        -- sorted set: current entities score with sizes
        entities = cache_key .. "::entities",

        -- hash: response headers
        headers = cache_key .. "::headers",

        -- hash: request headers for revalidation
        reval_params = cache_key .. "::reval_params",

        -- hash: request params for revalidation
        reval_req_headers = cache_key .. "::reval_req_headers",

    }, { __index = {
        -- Hide "root" and "fetching_lock" from iterators.
        root = cache_key,
        fetching_lock = cache_key .. "::fetching",
    }})
end


function _M.cache_key_chain(self)
    if type(self.t_cache_key_chain ~= "table") then
        local cache_key = self:cache_key()
        self.t_cache_key_chain = self:key_chain(cache_key)
    end
    return self.t_cache_key_chain
end


-- TODO response?
function _M.entity_id(self, key_chain)
    if not key_chain and key_chain.main then return nil end
    local redis = self.redis

    local entity_id, err = redis:hget(key_chain.main, "entity")
    if not entity_id or entity_id == ngx_null then
        return nil, err
    end

    return entity_id
end


-- TODO background? jobs?
-- Calculate when to GC an entity based on its size and the minimum download
-- rate setting, plus 1 second of arbitrary latency for good measure.
function _M.gc_wait(self, entity_size)
    local dl_rate_Bps = self.config.minimum_old_entity_download_rate * 128
    return math_ceil((entity_size / dl_rate_Bps)) + 1
end


-- TODO background
function _M.put_background_job(self, queue, klass, data, options)
    local q = qless.new({
        get_redis_client = require("ledge").create_qless_connection
    })

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

    q:redis_close()

    if res then
        return {
            jid = res,
            klass = klass,
            options = options,
        }
    else
        return res, err
    end
end


-- Attempts to set a lock key in redis. The lock will expire after
-- the expiry value if it is not cleared (i.e. in case of errors).
-- Returns true if the lock was acquired, false if the lock already
-- exists, and nil, err in case of failure.
function _M.acquire_lock(self, lock_key, timeout)
    local redis = self.redis

    -- We use a Lua script to emulate SETNEX (set if not exists with expiry).
    -- This avoids a race window between the GET / SETEX.
    -- Params: key, expiry
    -- Return: OK or BUSY
    local SETNEX = [[
    local lock = redis.call("GET", KEYS[1])
    if not lock then
        return redis.call("PSETEX", KEYS[1], ARGV[1], "locked")
    else
        return "BUSY"
    end
    ]]

    local res, err = redis:eval(SETNEX, 1, lock_key, timeout)

    if not res then -- Lua script failed
        return nil, err
    elseif res == "OK" then -- We have the lock
        return true
    elseif res == "BUSY" then -- Lock is busy
        return false
    end
end


-- TODO gzip
local zlib_output = function(data)
    co_yield(data)
end


-- TODO gzip
local function get_gzip_decoder(reader)
    return co_wrap(function(buffer_size)
        local ok, err = zlib.inflateGzip(reader, zlib_output, buffer_size)
        if not ok then
            ngx_log(ngx_ERR, err)
        end

        -- zlib decides it is done when the stream is complete. Call reader() one more time
        -- to resume the next coroutine in the chain.
        reader(buffer_size)
    end)
end
_M.get_gzip_decoder = get_gzip_decoder


-- TODO gzip
local function get_gzip_encoder(reader)
    return co_wrap(function(buffer_size)
        local ok, err = zlib.deflateGzip(reader, zlib_output, buffer_size)
        if not ok then
            ngx_log(ngx_ERR, err)
        end

        -- zlib decides it is done when the stream is complete.
        -- Call reader() one more time to resume the next coroutine in the chain
        reader(buffer_size)
    end)
end
_M.get_gzip_encoder = get_gzip_encoder


-- TODO response? This is called from state machine
function _M.add_warning(self, code)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local header = code .. ' ' .. req_visible_hostname()
    header = header .. ' "' .. WARNINGS[code] .. '"'
    tbl_insert(res.header["Warning"], header)
end


function _M.read_from_cache(self)
    local ctx = self

    local res = response.new(ctx, self:cache_key_chain())
    local ok, err = res:read()
    if not ok then
        if err then
            -- TODO: What conditions do we want this to happen? Surely we should
            -- just MISS on failure?
            error(err)
            return self:e "http_internal_server_error"
        else
            return nil
        end
    end

    if res.size > 0 then
        local storage = ctx.storage
        if not storage:exists(res.entity_id) then
            ngx.log(ngx.DEBUG, res.entity_id, " doesn't exist in storage")
            -- Should exist, so presumed evicted

            local delay = self:gc_wait(res.size)
            self:put_background_job("ledge_gc", "ledge.jobs.collect_entity", {
                entity_id = res.entity_id,
            }, {
                delay = res.size,
                tags = { "collect_entity" },
                priority = 10,
            })
            return nil -- MISS
        end

        res:filter_body_reader("cache_body_reader", storage:get_reader(res))
    end

    emit(self, "after_cache_read", res)
    return res
end


-- Fetches a resource from the origin server.
function _M.fetch_from_origin(self)
    local res = response.new(self, self:cache_key_chain())

    local method = ngx['HTTP_' .. ngx_req_get_method()]
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    local httpc
    if self:config_get("use_resty_upstream") then
        httpc = self:config_get("resty_upstream")
    else
        httpc = http.new()
        httpc:set_timeout(self:config_get("upstream_connect_timeout"))

        local ok, err = httpc:connect(self:config_get("upstream_host"), self:config_get("upstream_port"))

        if not ok then
            if err == "timeout" then
                res.status = 524 -- upstream server timeout
            else
                res.status = 503
            end
            return res
        end

        httpc:set_timeout(self:config_get("upstream_read_timeout"))

        if self:config_get("upstream_use_ssl") == true then
            local ok, err = httpc:ssl_handshake(false,
                                                self:config_get("upstream_ssl_server_name"),
                                                self:config_get("upstream_ssl_verify"))
            if not ok then
                ngx_log(ngx_ERR, "ssl handshake failed: ", err)
                res.status = 525 -- SSL Handshake Failed
                return res
            end
        end
    end

    res.conn = httpc

    -- Case insensitve headers so that we can safely manipulate them
    local headers = http_headers.new()
    for k,v in pairs(ngx_req_get_headers()) do
        headers[k] = v
    end

    -- Advertise ESI surrogate capabilities
    if self:config_get("esi_enabled") then
        local capability_entry =    (ngx_var.visible_hostname or ngx_var.hostname)
                                    .. '="' .. esi.esi_capabilities() .. '"'
        local sc = headers.surrogate_capability

        if not sc then
            headers.surrogate_capability = capability_entry
        else
            headers.surrogate_capability = sc .. ", " .. capability_entry
        end
    end

    local client_body_reader, err = httpc:get_client_body_reader(self:config_get("buffer_size"))
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

    local origin, err = httpc:request(req_params)

    if not origin then
        ngx_log(ngx_ERR, err)
        res.status = 524
        return res
    end

    res.status = origin.status

    -- Merge end-to-end headers
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

    for k,v in pairs(origin.headers) do
        if not hop_by_hop_headers[str_lower(k)] then
            res.header[k] = v
        end
    end

    -- May well be nil, but if present we bail on saving large bodies to memory nice
    -- and early.
    res.length = tonumber(origin.headers["Content-Length"])

    res.has_body = origin.has_body
    res:filter_body_reader(
        "upstream_body_reader",
        origin.body_reader
    )

    if res.status < 500 then
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx_parse_http_time(res.header["Date"]) then
            ngx_log(ngx_WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx_http_time(ngx_time())
        end
    end

    -- A nice opportunity for post-fetch / pre-save work.
    emit(self, "after_upstream_request", res)

    return res
end


-- TODO background?
--
-- Returns data required to perform a background revalidation for this current
-- request, as two tables; reval_params and reval_headers.
function _M.revalidation_data(self)
    -- Everything that a headless revalidation job would need to connect
    local reval_params = {
        server_addr = ngx_var.server_addr,
        server_port = ngx_var.server_port,
        scheme = ngx_var.scheme,
        uri = ngx_var.request_uri,
        connect_timeout = self:config_get("upstream_connect_timeout"),
        read_timeout = self:config_get("upstream_read_timeout"),
        ssl_server_name = self:config_get("upstream_ssl_server_name"),
        ssl_verify = self:config_get("upstream_ssl_verify"),
    }

    local h = ngx_req_get_headers()
    -- By default we pass through Host, and Authorization and Cookie headers if present.
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


-- TODO background
function _M.revalidate_in_background(self, update_revalidation_data)
    local redis = self.redis
    local key_chain = self:cache_key_chain()

    -- Revalidation data is updated if this is a proper request, but not if it's a purge request.
    if update_revalidation_data then
        local reval_params, reval_headers = self:revalidation_data()

        local ttl, err = redis:ttl(key_chain.reval_params)
        if not ttl or ttl == ngx_null or ttl < 0 then
            ngx_log(ngx_ERR, "Could not determine expiry for revalidation params. Will fallback to 3600 seconds.")
            ttl = 3600 -- Arbitrarily expire these revalidation parameters in an hour.
        end

        -- Delete and update reval request headers
        redis:multi()

        redis:del(key_chain.reval_params)
        redis:hmset(key_chain.reval_params, reval_params)
        redis:expire(key_chain.reval_params, ttl)

        redis:del(key_chain.reval_req_headers)
        redis:hmset(key_chain.reval_req_headers, reval_headers)
        redis:expire(key_chain.reval_req_headers, ttl)

        local res, err = redis:exec()
        if not res then
            ngx_log(ngx_ERR, "Could not update revalidation params: ", err)
        end
    end

    local uri, err = redis:hget(key_chain.main, "uri")
    if not uri or uri == ngx_null then
        ngx_log(ngx_ERR, "Cache key has no 'uri' field, aborting revalidation")
        return nil
    end

    -- Schedule the background job (immediately). jid is a function of the
    -- URI for automatic de-duping.
    return self:put_background_job("ledge_revalidate", "ledge.jobs.revalidate", {
        key_chain = key_chain,
    }, {
        jid = ngx_md5("revalidate:" .. uri),
        tags = { "revalidate" },
        priority = 4,
    })
end


-- TODO background
--
-- Starts a "revalidation" job but maybe for brand new cache. We pass the current
-- request's revalidation data through so that the job has meaningul parameters to
-- work with (rather than using stored metadata).
function _M.fetch_in_background(self)
    local key_chain = self:cache_key_chain()
    local reval_params, reval_headers = self:revalidation_data()
    return self:put_background_job("ledge_revalidate", "ledge.jobs.revalidate", {
        key_chain = key_chain,
        reval_params = reval_params,
        reval_headers = reval_headers,
    }, {
        jid = ngx_md5("revalidate:" .. req_full_uri()),
        tags = { "revalidate" },
        priority = 4,
    })
end


function _M.save_to_cache(self, res)
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
    local key_chain = self:cache_key_chain()
    local redis = self.redis
    redis:watch(key_chain.main)

    -- We'll need to mark the old entity for expiration shortly, as reads could still
    -- be in progress. We need to know the previous entity keys and the size.
    local previous_entity_id = self:entity_id(key_chain)

    local previous_entity_size, err
    if previous_entity_id then
        previous_entity_size, err = redis:hget(key_chain.main, "size")
        if previous_entity_size == ngx_null then
            previous_entity_id = nil
            if err then
                ngx_log(ngx_ERR, err)
            end
        end
    end

    -- Start the transaction
    local ok, err = redis:multi()
    if not ok then ngx_log(ngx_ERR, err) end

    if previous_entity_id then
        self:put_background_job("ledge_gc", "ledge.jobs.collect_entity", {
            entity_id = previous_entity_id,
        }, {
            delay = previous_entity_size,
            tags = { "collect_entity" },
            priority = 10,
        })

        local ok, err = redis:srem(key_chain.entities, previous_entity_id)
        if not ok then ngx_log(ngx_ERR, err) end
    end


    -- TODO: Is this supposed to be total ttl + keep_cache_for?
    local keep_cache_for = self:config_get("keep_cache_for")

    res.uri = req_full_uri()
    local ok, err = res:save(keep_cache_for)
    -- TODO: Do somethign with this err?

    -- Set revalidation parameters from this request
    local reval_params, reval_headers = self:revalidation_data()

    -- TODO: Catch errors
    redis:del(key_chain.reval_params)
    redis:hmset(key_chain.reval_params, reval_params)
    redis:expire(key_chain.reval_params, keep_cache_for)

    -- TODO: Catch errors
    redis:del(key_chain.reval_req_headers)
    redis:hmset(key_chain.reval_req_headers, reval_headers)
    redis:expire(key_chain.reval_req_headers, keep_cache_for)

    -- If we have a body, we need to attach the storage writer
    -- NOTE: res.has_body is false for known bodyless repsonse types (e.g. HEAD)
    -- but may be true and of zero length (commonly 301 etc).
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
            if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
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
        if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
    end
end


function _M.delete(redis, key_chain)
    local keys = {}
    for k, v in pairs(key_chain) do
        tbl_insert(keys, v)
    end
    return redis:del(unpack(keys))
end


function _M.delete_from_cache(self)
    local redis = self.redis
    local key_chain = self:cache_key_chain()

    local entity_id = self:entity_id(key_chain)

    if entity_id then
        local size = redis:hget(key_chain.main, "size")
        self:put_background_job("ledge_gc", "ledge.jobs.collect_entity", {
            entity_id = entity_id,
        }, {
            delay = self:gc_wait(size),
            tags = { "collect_entity" },
            priority = 10,
        })
    end

    -- Delete everything else immediately
    return _M.delete(redis, key_chain)
end


-- TODO purge
--
-- Purges the cache item according to X-Purge instructions, which defaults to "invalidate".
-- If there's nothing to do we return false which results in a 404.
function _M.purge(self, purge_mode)
    local redis = self.redis
    local key_chain = self:cache_key_chain()
    local entity_id, err = redis:hget(key_chain.main, "entity")
    local storage = self.storage

    local resp = self:get_response()

    -- We 404 if we have nothing
    if not entity_id or entity_id == ngx_null or not storage:exists(entity_id) then
        local json = cjson_encode({ purge_mode = purge_mode, result = "nothing to purge" })
        resp:set_body(json)
        self:set_response(resp)
        return false
    end

    -- Delete mode overrides everything else, since you can't revalidate
    if purge_mode == "delete" then
        local result = "deleted"
        local res, err = self:delete_from_cache()
        if not res then
            result = err
        end

        local json = cjson_encode({ purge_mode = purge_mode, result = result })
        resp:set_body(json)
        self:set_response(resp)
        return true
    end

    -- If we're revalidating, fire off the background job
    local job
    if purge_mode == "revalidate" then
        job = self:revalidate_in_background(false)
    end

    -- Invalidate the keys
    local entity_id = self:entity_id(key_chain)
    local ok, err = self:expire_keys(key_chain, entity_id)

    local result
    if not ok and err then
        result = err
    elseif not ok then
        result = "already expired"
    elseif ok then
        result = "purged"
    end

    local json = {
        purge_mode = purge_mode,
        result = result
    }
    if job then json.qless_job = job end

    resp:set_body(cjson_encode(json))
    self:set_response(resp)

    return ok
end


-- TODO purge or background?
function _M.purge_in_background(self)
    local key_chain = self:cache_key_chain()
    local purge_mode = req_purge_mode()

    local job, err = self:put_background_job("ledge_purge", "ledge.jobs.purge", {
        key_chain = key_chain,
        keyspace_scan_count = self:config_get("keyspace_scan_count"),
        purge_mode = purge_mode,
    }, {
        jid = ngx_md5("purge:" .. key_chain.root),
        tags = { "purge" },
        priority = 5,
    })

    -- Create a JSON payload for the response
    local res = self:get_response()
    local _, json = pcall(cjson_encode, {
        purge_mode = purge_mode,
        result = "scheduled",
        qless_job = job
    })
    res:set_body(json)
    self:set_response(res)

    return true
end


-- Expires the keys in key_chain and the entity provided by entity_keys
function _M.expire_keys(self, key_chain, entity_id)
    local redis = self.redis
    local storage = self.storage

    local exists, err =  redis:exists(key_chain.main)
    if exists == 1 then
        local time = ngx_time()
        local expires, err = redis:hget(key_chain.main, "expires")
        if not expires or expires == ngx_null then
            return nil, "could not determine existing expiry: " .. (err or "")
        end

        -- If expires is in the past then this key is stale. Nothing to do here.
        if tonumber(expires) <= time then
            return false, nil
        end

        local ttl, err = redis:ttl(key_chain.main)
        if not ttl or ttl == ngx_null then
            return nil, "count not determine exsiting ttl: " .. (err or "")
        end

        local ttl_reduction = expires - time
        if ttl_reduction < 0 then ttl_reduction = 0 end

        redis:multi()

        -- Set the expires field of the main key to the new time, to control
        -- its validity.
        redis:hset(key_chain.main, "expires", tostring(time - 1))

        -- Set new TTLs for all keys in the key chain
        key_chain.fetching_lock = nil -- this looks after itself
        for _,key in pairs(key_chain) do
            redis:expire(key, ttl - ttl_reduction)
        end

        storage:set_ttl(entity_id, ttl - ttl_reduction)

        local ok, err = redis:exec()
        if err then
            return nil, err
        else
            return true, nil
        end
    else
        return false, nil
    end
end


function _M.serve(self)
    if not ngx.headers_sent then
        local res = self:get_response()
        local visible_hostname = req_visible_hostname()

        -- Via header
        local via = "1.1 " .. visible_hostname
        if self:config_get("advertise_ledge") then
            via = via .. " (ledge/" .. _M._VERSION .. ")"
        end
        local res_via = res.header["Via"]
        if  (res_via ~= nil) then
            res.header["Via"] = via .. ", " .. res_via
        else
            res.header["Via"] = via
        end

        -- X-Cache header
        -- Don't set if this isn't a cacheable response. Set to MISS is we fetched.
        local ctx = self
        local state_history = self.state_machine.state_history
        local event_history = self.state_machine.event_history

        if not event_history["response_not_cacheable"] then
            local x_cache = "HIT from " .. visible_hostname
            if not event_history["can_serve_disconnected"]
                and not event_history["can_serve_stale"]
                and state_history["fetching"] then

                x_cache = "MISS from " .. visible_hostname
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

        local cjson = require "cjson"

        if res.body_reader and ngx_req_get_method() ~= "HEAD" then
            local buffer_size = self:config_get("buffer_size")
            self:serve_body(res, buffer_size)
        end

        ngx.eof()
    end
end


-- Resumes the reader coroutine and prints the data yielded. This could be
-- via a cache read, or a save via a fetch... the interface is uniform.
function _M.serve_body(self, res, buffer_size)
    local buffered = 0
    local reader = res.body_reader
    local can_flush = ngx_req_http_version() >= 1.1
    local ctx = self

    repeat
        local chunk, err = reader(buffer_size)
        if chunk and ctx.output_buffers_enabled then
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


return setmetatable(_M, fixed_field_metatable)
