local cjson = require "cjson"
local http = require "resty.http"
local http_headers = require "resty.http_headers"
local qless = require "resty.qless"
local response = require "ledge.response"
local range = require "ledge.range"
local h_util = require "ledge.header_util"
local esi = require "ledge.esi"
require "ledge.util"

local zlib = require "ffi-zlib"
local redis = require "resty.redis"
local redis_connector = require "resty.redis.connector"

local   tostring, ipairs, pairs, type, tonumber, next, unpack =
        tostring, ipairs, pairs, type, tonumber, next, unpack

local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_NOTICE = ngx.NOTICE
local ngx_INFO = ngx.INFO
local ngx_null = ngx.null
local ngx_print = ngx.print
local ngx_flush = ngx.flush
local ngx_get_phase = ngx.get_phase
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_req_get_method = ngx.req.get_method
local ngx_req_raw_header = ngx.req.raw_header
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_req_set_uri_args = ngx.req.set_uri_args
local ngx_req_http_version = ngx.req.http_version
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_re_gsub = ngx.re.gsub
local ngx_re_sub = ngx.re.sub
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_find = ngx.re.find
local ngx_var = ngx.var
local ngx_timer_at = ngx.timer.at
local ngx_sleep = ngx.sleep
local ngx_md5 = ngx.md5
local ngx_encode_args = ngx.encode_args
local ngx_encode_args = ngx.encode_args
local ngx_PARTIAL_CONTENT = 206
local ngx_RANGE_NOT_SATISFIABLE = 416
local ngx_HTTP_NOT_MODIFIED = 304

local tbl_insert = table.insert
local tbl_concat = table.concat
local tbl_remove = table.remove
local tbl_getn = table.getn
local tbl_sort = table.sort
local tbl_copy = table.copy

local str_lower = string.lower
local str_sub = string.sub
local str_match = string.match
local str_gmatch = string.gmatch
local str_find = string.find
local str_lower = string.lower
local str_len = string.len
local str_rep = string.rep
local str_split = string.split
local str_randomhex = string.randomhex

local math_floor = math.floor
local math_ceil = math.ceil
local math_min = math.min

local co_yield = coroutine.yield
local co_wrap = coroutine.wrap
local cjson_encode = cjson.encode


-- Body reader for when the response body is missing
local function _no_body_reader()
    return nil
end


local function _purge_mode()
    local x_purge = ngx_req_get_headers()["X-Purge"]
    if h_util.header_has_directive(x_purge, "delete") then
        return "delete"
    elseif h_util.header_has_directive(x_purge, "revalidate") then
        return "revalidate"
    else
        return "invalidate"
    end
end


local _M = {
    _VERSION = '1.28.3',
    DEBUG = false,

    ORIGIN_MODE_BYPASS = 1, -- Never go to the origin, serve from cache or 503.
    ORIGIN_MODE_AVOID  = 2, -- Avoid the origin, serve from cache where possible.
    ORIGIN_MODE_NORMAL = 4, -- Assume the origin is happy, use at will.
}

local mt = {
    __index = _M,
}


-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
    ["content-length"]      = true, -- Not strictly hop-by-hop, but we set dynamically downstream.
}

local WARNINGS = {
    ["110"] = "Response is stale",
    ["214"] = "Transformation applied",
    ["112"] = "Disconnected Operation",
}


function _M.new(self)
    local config = {
        origin_mode     = _M.ORIGIN_MODE_NORMAL,

        -- Redis connection settings
        redis_connect_timeout = 500,    -- (ms) Connect timeout
        redis_read_timeout = 5000,      -- (ms) Read/write timeout
        redis_connection_options = nil, -- Additional options passed to tcpsock:connect

        -- Redis keepalive settings
        redis_keepalive_timeout = nil,  -- (sec) Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- (sec) Defaults to 30 or lua_socket_pool_size

        -- Redis connection DSN (as supplied to lua-resty-redis-connector)
        redis_connection = {
            url = "redis://127.0.0.1:6379/0", -- The Redis DSN for cache metadata
        },

        -- Redis database for Qless jobs
        redis_qless_database = 1,

        storage_connection = {
            url = "redis://127.0.0.1:6379/0", -- DSN for data storage
        },

        upstream_connect_timeout = 500,
        upstream_read_timeout = 5000,
        upstream_host = "",
        upstream_port = 80,
        upstream_use_ssl = false,
        upstream_ssl_server_name = nil,
        upstream_ssl_verify = true,

        use_resty_upstream = false,
        resty_upstream = nil,   -- An instance of lua-resty-upstream, which if enabled will override
                                -- upstream_* settings above.

        buffer_size = 2^16, -- 65536 (bytes) (64KB) Internal buffer size for data read/written/served.
        cache_max_memory = 2048, -- (KB) Max size for a cache item before we bail on trying to store.

        advertise_ledge = true, -- Set this to false to omit (ledge/_VERSION) from the "Server" response header.


        keep_cache_for  = 86400 * 30,   -- (sec) Max time to keep cache items past expiry + stale.
                                        -- Items will be evicted when under memory pressure, so this
                                        -- setting is just about trying to keep cache around to serve
                                        -- stale in the event of origin disconnection.

        minimum_old_entity_download_rate = 56,  -- (kbps). Slower clients than this unfortunate enough
                                                -- to be reading from replaced (in memory) entities will
                                                -- have their entity garbage collected before they finish.

        esi_enabled      = false,
        esi_content_types = { "text/html" },
        esi_allow_surrogate_delegation = false, -- Set to true to delegate to any downstream host
                                                -- that sets the Surrogate-Capability header, or to
                                                -- a table of IP addresses to limit to. e.g.
                                                -- { "1.2.3.4", "5.6.7.8" }
        esi_recursion_limit = 10,   -- ESI fragment nesting beyond this limit of recursion is considered
                                    -- to be an accidental loop.
        esi_pre_include_callback = nil, -- A function to modify the outbound HTTP request parameters
                                        -- for an ESI include.
                                        -- e.g. ledge:config_set("esi_pre_include_callback", function(req_params)
                                        --          req_params.headers["X-My-Header"] = "foo"
                                        --      end)
        esi_args_prefix = "esi_",   -- URI args prefix for parameters to be ignored from the cache key (and not
                                    -- proxied upstream), for use exclusively with ESI rendering logic. Set
                                    -- to nil to disable the feature.

        enable_collapsed_forwarding = false,
        collapsed_forwarding_window = 60 * 1000, -- Window for collapsed requests (ms)

        gunzip_enabled = true,  -- Auto gunzip compressed responses for requests
                                -- which do not support gzip encoding.

        keyspace_scan_count = 10,   -- Limits the size of results returned from each keyspace scan command.
                                    -- A wildcard PURGE request will result in keyspace_size / keyspace_scan_count
                                    -- redis commands over the wire, but larger numbers block redis for longer.

    }

    return setmetatable({ config = config }, mt)
end


-- A safe place in ngx.ctx for the current module instance (self).
function _M.ctx(self)
    local id = tostring(self)
    local ctx = ngx.ctx[id]
    if not ctx then
        ctx = {
            events = {},
            config = {},
            state_history = {},
            event_history = {},
            current_state = "",
            client_validators = {},
            output_buffers_enabled = true,
        }
        ngx.ctx[id] = ctx
    end
    return ctx
end


-- Set a config parameter
function _M.config_set(self, param, value)
    if ngx_get_phase() == "init" then
        self.config[param] = value
    else
        self:ctx().config[param] = value
    end
end


-- Gets a config parameter.
function _M.config_get(self, param)
    local p = self:ctx().config[param]
    if p == nil then
        local static = self.config[param]
        if type(static) == "table" then
            return tbl_copy(static)
        else
            return static
        end
    else
        return p
    end
end


function _M.handle_abort(self)
    -- Use a closure to pass through the ledge instance
    return function()
        return self:e "aborted"
    end
end


function _M.bind(self, event, callback)
    local events = self:ctx().events
    if not events[event] then events[event] = {} end
    tbl_insert(events[event], callback)
end


function _M.emit(self, event, ...)
    local events = self:ctx().events
    for _, handler in ipairs(events[event] or {}) do
        if type(handler) == "function" then
            local ok, err = pcall(handler, ...)
            if not ok then
                ngx_log(ngx_ERR, "Error in user callback for '", event, "': ", err)
            end
        end
    end
end


function _M.run(self)
    local set, msg = ngx.on_abort(self:handle_abort())
    if set == nil then
       ngx_log(ngx_WARN, "on_abort handler not set: "..msg)
    end
    return self:e "init"
end


function _M.run_workers(self, options)
    if not options then options = {} end
    local resty_qless_worker = require "resty.qless.worker"

    local redis_params = self:config_get("redis_connection")
    redis_params.db = self:config_get("redis_qless_database")

    local connection_options = {
        connect_timeout = self:config_get("redis_connect_timeout"),
        read_timeout = self:config_get("redis_read_timeout"),
    }

    local worker = resty_qless_worker.new(redis_params, connection_options)
    worker.middleware = function(job)
        self:e "init_worker"
        job.redis = self:ctx().redis
        job.storage = self:ctx().storage
        -- Pass though connection params in case jobs need to
        -- connect to a slave or anything of that nature.
        job.redis_params = self:ctx().redis_params
        job.redis_connection_options = connection_options
        job.redis_qless_database = redis_params.db

        co_yield() -- Perform the job

        return self:e "worker_finished"
    end

    worker:start({
        interval = options.interval or 1,
        concurrency = options.concurrency or 1,
        reserver = "ordered",
        queues = { "ledge" },
    })

    worker:start({
        interval = options.interval or 1,
        concurrency = options.purge_concurrency or 1,
        reserver = "ordered",
        queues = { "ledge_purge" },
    })

    worker:start({
        interval = options.interval or 1,
        concurrency = options.revalidate_concurrency or 1,
        reserver = "ordered",
        queues = { "ledge_revalidate" },
    })
end


function _M.relative_uri(self)
    local uri = ngx_re_gsub(ngx_var.uri, "\\s", "%20", "jo") -- encode spaces

    -- encode percentages if an encoded CRLF is in the URI
    -- see: http://resources.infosecinstitute.com/http-response-splitting-attack/
    uri = ngx_re_gsub(uri, "%0D%0A", "%250D%250A", "ijo")

    return uri .. ngx_var.is_args .. (ngx_var.query_string or "")
end


function _M.full_uri(self)
    return ngx_var.scheme .. '://' .. ngx_var.host .. self:relative_uri()
end


function _M.visible_hostname(self)
    local name = ngx_var.visible_hostname or ngx_var.hostname
    local server_port = ngx_var.server_port
    if server_port ~= "80" and server_port ~= "443" then
        name = name .. ":" .. server_port
    end
    return name
end


-- Close and optionally keepalive the redis connection
function _M.redis_close(self)
    local redis = self:ctx().redis
    if redis then
        -- We should only be able to close outside of the transactional
        -- code (as abort gets suspended on write), but just in case we
        -- restore this connection to "NORMAL" before putting it in the
        -- keepalive pool.
        redis:discard()

        -- Keep the Redis connection based on keepalive settings.
        local ok, err = nil, nil
        local keepalive_timeout = self:config_get("redis_keepalive_timeout")
        if keepalive_timeout then
            if self:config_get("redis_keepalive_pool_size") then
                ok, err = redis:set_keepalive(keepalive_timeout,
                self:config_get("redis_keepalive_pool_size"))
            else
                ok, err = redis:set_keepalive(keepalive_timeout)
            end
        else
            ok, err = redis:set_keepalive()
        end

        if not ok then
            ngx_log(ngx_WARN, "couldn't set keepalive, ", err)
        end
    end
end


function _M.request_accepts_cache(self)
    -- Check for no-cache
    local h = ngx_req_get_headers()
    if h_util.header_has_directive(h["Pragma"], "no-cache")
       or h_util.header_has_directive(h["Cache-Control"], "no-cache")
       or h_util.header_has_directive(h["Cache-Control"], "no-store") then
        return false
    end

    return true
end


-- True if the request specifically asks for stale (req.cc.max-stale) and the response
-- doesn't explicitly forbid this res.cc.(must|proxy)-revalidate.
function _M.can_serve_stale(self)
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_max_stale = h_util.get_numeric_header_token(req_cc, "max-stale")
    if req_cc_max_stale then
        local res = self:get_response()
        local res_cc = res.header["Cache-Control"]

        -- Check the response permits this at all
        if h_util.header_has_directive(res_cc, "(must|proxy)-revalidate") then
            return false
        else
            if (req_cc_max_stale * -1) <= res.remaining_ttl then
                return true
            else
            end
        end
    end
    return false
end


-- Returns true if stale-while-revalidate or stale-if-error is specified, valid
-- and not constrained by other factors such as max-stale.
-- @param   token  "stale-while-revalidate" | "stale-if-error"
function _M.verify_stale_conditions(self, token)
    local res = self:get_response()
    local res_cc = res.header["Cache-Control"]
    local res_cc_stale = h_util.get_numeric_header_token(res_cc, token)

    -- Check the response permits this at all
    if h_util.header_has_directive(res_cc, "(must|proxy)-revalidate") then
        return false
    end

    -- Get request header tokens
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_stale = h_util.get_numeric_header_token(req_cc, token)
    local req_cc_max_age = h_util.get_numeric_header_token(req_cc, "max-age")
    local req_cc_max_stale = h_util.get_numeric_header_token(req_cc, "max-stale")

    local stale_ttl = 0
    -- If we have both req and res stale-" .. reason, use the lower value
    if req_cc_stale and res_cc_stale then
        stale_ttl = math_min(req_cc_stale, res_cc_stale)
    -- Otherwise return the req or res value
    elseif req_cc_stale then
        stale_ttl = req_cc_stale
    elseif res_cc_stale then
        stale_ttl = res_cc_stale
    end

    if stale_ttl <= 0 then
        return false -- No stale policy defined
    elseif h_util.header_has_directive(req_cc, "min-fresh") then
        return false -- Cannot serve stale as request demands freshness
    elseif req_cc_max_age and req_cc_max_age < (res.header["Age"] or 0) then
        return false -- Cannot serve stale as req max-age is less than res Age
    elseif req_cc_max_stale and req_cc_max_stale < stale_ttl then
        return false -- Cannot serve stale as req max-stale is less than S-W-R policy
    else
        -- We can return stale
        return true
    end
end


function _M.can_serve_stale_while_revalidate(self)
    return self:verify_stale_conditions("stale-while-revalidate")
end


function _M.can_serve_stale_if_error(self)
    return self:verify_stale_conditions("stale-if-error")
end


function _M.must_revalidate(self)
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_max_age = h_util.get_numeric_header_token(req_cc, "max-age")
    if req_cc_max_age == 0 then
        return true
    else
        local res = self:get_response()
        local res_age = res.header["Age"]
        local res_cc = res.header["Cache-Control"]

        if h_util.header_has_directive(res_cc, "(must|proxy)-revalidate") then
            return true
        elseif req_cc_max_age and res_age then
            if req_cc_max_age < res_age then
                return true
            end
        end
    end
    return false
end


function _M.can_revalidate_locally(self)
    local req_h = ngx_req_get_headers()
    local req_ims = req_h["If-Modified-Since"]

    if req_ims then
        if not ngx_parse_http_time(req_ims) then
            -- Bad IMS HTTP datestamp, lets remove this.
            ngx_req_set_header("If-Modified-Since", nil)
        else
            return true
        end
    end

    if req_h["If-None-Match"] then
        return true
    end

    return false
end


function _M.is_valid_locally(self)
    local req_h = ngx_req_get_headers()
    local res = self:get_response()

    local res_lm = res.header["Last-Modified"]
    local req_ims = req_h["If-Modified-Since"]

    if res_lm and req_ims then
        local res_lm_parsed = ngx_parse_http_time(res_lm)
        local req_ims_parsed = ngx_parse_http_time(req_ims)

        if res_lm_parsed and req_ims_parsed then
            if res_lm_parsed <= req_ims_parsed then
                return true
            end
        end
    end

    local res_etag = res.header["Etag"]
    local req_inm = req_h["If-None-Match"]
    if res_etag and req_inm and res_etag == req_inm then
        return true
    end

    return false
end


function _M.set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end


function _M.get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


-- Generates or returns the cache key. The default spec is:
-- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
function _M.cache_key(self)
    if not self:ctx().cache_key then

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

        local key_spec = self:config_get("cache_key_spec") or {
            ngx_var.scheme,
            ngx_var.host,
            ngx_var.uri,
            args,
        }
        tbl_insert(key_spec, 1, "cache")
        tbl_insert(key_spec, 1, "ledge")
        self:ctx().cache_key = tbl_concat(key_spec, ":")
    end
    return self:ctx().cache_key
end


-- Returns the key chain for all cache keys, except the body entity
function _M.key_chain(self, cache_key)
    return setmetatable({
        main = cache_key .. "::main", -- hash: cache key metadata
        entities = cache_key .. "::entities", -- sorted set: current entities score with sizes
        headers = cache_key .. "::headers", -- hash: response headers
        reval_params = cache_key .. "::reval_params", -- hash: request headers for revalidation
        reval_req_headers = cache_key .. "::reval_req_headers", -- hash: request params for revalidation
    }, { __index = {
        -- Hide "root" and "fetching_lock" from iterators.
        root = cache_key,
        fetching_lock = cache_key .. "::fetching",
    }})
end


function _M.cache_key_chain(self)
    if not self:ctx().cache_key_chain then
        local cache_key = self:cache_key()
        self:ctx().cache_key_chain = self:key_chain(cache_key)
    end
    return self:ctx().cache_key_chain
end


function _M.entity_id(self, key_chain)
    if not key_chain and key_chain.main then return nil end
    local redis = self:ctx().redis

    local entity_id, err = redis:hget(key_chain.main, "entity")
    if not entity_id or entity_id == ngx_null then
        return nil, err
    end

    return entity_id
end


-- Calculate when to GC an entity based on its size and the minimum download rate setting,
-- plus 1 second of arbitrary latency for good measure.
-- TODO: Move to util
function _M.gc_wait(self, entity_size)
    local dl_rate_Bps = self:config_get("minimum_old_entity_download_rate") * 128 -- Bytes in a kb
    return math_ceil((entity_size / dl_rate_Bps)) + 1
end


function _M.put_background_job(self, queue, klass, data, options)
    local redis = self:ctx().redis
    local redis_params = self:ctx().redis_params
    local redis_db = redis_params.db
    local qless_db = self:config_get("redis_qless_database") or 1

    redis:select(qless_db)
    local q = qless.new({ redis_client = redis })

    -- If we've been specified a jid (i.e. a non random jid), putting this
    -- job will overwrite any existing job with the same jid.
    -- We test for a "running" state, and if so we silently drop this job.
    if options.jid then
        local existing = q.jobs:get(options.jid)

        if existing and existing.state == "running" then
            redis:select(redis_db or 0)
            return nil, "Job with the same jid is currently running"
        end
    end

    -- Put the job
    local res, err = q.queues[queue]:put(klass, data, options)
    redis:select(redis_db or 0)

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
    local redis = self:ctx().redis

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


local zlib_output = function(data)
    co_yield(data)
end


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


local function get_gzip_encoder(reader)
    return co_wrap(function(buffer_size)
        local ok, err = zlib.deflateGzip(reader, zlib_output, buffer_size)
        if not ok then
            ngx_log(ngx_ERR, err)
        end

        -- zlib decides it is done when the stream is complete. Call reader() one more time
        -- to resume the next coroutine in the chain.
        reader(buffer_size)
    end)
end


function _M.add_warning(self, code)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local header = code .. ' ' .. self:visible_hostname() .. ' "' .. WARNINGS[code] .. '"'
    tbl_insert(res.header["Warning"], header)
end


---------------------------------------------------------------------------------------------------
-- Event transition table.
---------------------------------------------------------------------------------------------------
-- Use "begin" to transition based on an event. Filter transitions by current state "when", and/or
-- any previous state "after", and/or a previously fired event "in_case", and run actions using
-- "but_first". Transitions are processed in the order found, so place more specific entries for a
-- given event before more generic ones.
---------------------------------------------------------------------------------------------------
_M.events = {
    -- Initial transition. Connect to redis.
    init = {
        { begin = "connecting_to_redis" },
    },

    -- Entry point for worker scripts, which need to connect to Redis but
    -- will stop when this is done.
    init_worker = {
        { begin = "connecting_to_redis" },
    },

    -- Background worker who slept due to redis connection failure, has awoken
    -- to try again.
    woken = {
        { begin = "connecting_to_redis" }
    },

    worker_finished = {
        { begin = "exiting_worker" }
    },

    -- We failed to connect to redis. Bail.
    redis_connection_failed = {
        { in_case = "init_worker", begin = "sleeping" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    redis_connected = {
        { begin = "connecting_to_storage" },
    },

    storage_connection_failed = {
        { in_case = "init_worker", begin = "sleeping" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    -- We're connected! Let's get on with it then... First step, analyse the request.
    -- If we're a worker then we just start running tasks.
    storage_connected = {
        { in_case = "init_worker", begin = "running_worker" },
        { begin = "checking_method", but_first = "filter_esi_args" },
    },

    cacheable_method = {
        { when = "checking_origin_mode", begin = "checking_request" },
        { begin = "checking_origin_mode" },
    },

    -- PURGE method detected.
    purge_requested = {
        { when = "considering_wildcard_purge", begin = "purging", but_first = "set_json_response" },
        { begin = "considering_wildcard_purge" },
    },

    wildcard_purge_requested = {
        { begin = "wildcard_purging", but_first = "set_json_response" },
    },

    -- Succesfully purged (expired) a cache entry. Exit 200 OK.
    purged = {
        { begin = "serving", but_first = "set_http_ok" },
    },

    wildcard_purge_scheduled = {
        { begin = "serving", but_first = "set_http_ok" },
    },

    -- URI to purge was not found. Exit 404 Not Found.
    nothing_to_purge = {
        { begin = "serving", but_first = "set_http_not_found" },
    },

    -- The request accepts cache. If we've already validated locally, we can think about serving.
    -- Otherwise we need to check the cache situtation.
    cache_accepted = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
        { begin = "checking_cache" },
    },

    forced_cache = {
        { begin = "accept_cache" },
    },

    -- This request doesn't accept cache, so we need to see about fetching directly.
    cache_not_accepted = {
        { begin = "checking_can_fetch" },
    },

    -- We don't know anything about this URI, so we've got to see about fetching.
    cache_missing = {
        { begin = "checking_can_fetch" },
    },

    -- This URI was cacheable last time, but has expired. So see about serving stale, but failing
    -- that, see about fetching.
    cache_expired = {
        { when = "checking_cache", begin = "checking_can_serve_stale" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch" },
    },

    -- We have a (not expired) cache entry. Lets try and validate in case we can exit 304.
    cache_valid = {
        { in_case = "forced_cache", begin = "considering_esi_process" },
        { in_case = "collapsed_response_ready", begin = "considering_local_revalidation" },
        { when = "checking_cache", begin = "considering_revalidation" },
    },

    -- We need to fetch, and there are no settings telling us we shouldn't, but collapsed forwarding
    -- is on, so if cache is accepted and in an "expired" state (i.e. not missing), lets try
    -- to collapse. Otherwise we just start fetching.
    can_fetch_but_try_collapse = {
        { in_case = "cache_missing", begin = "fetching" },
        { in_case = "cache_accepted", begin = "requesting_collapse_lock" },
        { begin = "fetching" },
    },

    -- We have the lock on this "fetch". We might be the only one. We'll never know. But we fetch
    -- as "surrogate" in case others are listening.
    obtained_collapsed_forwarding_lock = {
        { begin = "fetching_as_surrogate" },
    },

    -- Another request is currently fetching, so we've subscribed to updates on this URI. We need
    -- to block until we hear something (or timeout).
    subscribed_to_collapsed_forwarding_channel = {
        { begin = "waiting_on_collapsed_forwarding_channel" },
    },

    -- Another request was fetching when we asked, but by the time we subscribed the channel was
    -- closed (small window, but potentially possible). Chances are the item is now in cache,
    -- so start there.
    collapsed_forwarding_channel_closed = {
        { begin = "checking_cache" },
    },

    -- We were waiting on a collapse channel, and got a message saying the response is now ready.
    -- The item will now be fresh in cache.
    collapsed_response_ready = {
        { begin = "checking_cache" },
    },

    -- We were waiting on another request (collapsed), but it came back as a non-cacheable response
    -- (i.e. the previously cached item is no longer cacheable). So go fetch for ourselves.
    collapsed_forwarding_failed = {
        { begin = "fetching" },
    },

    -- We were waiting on another request, but it received an upstream_error (e.g. 500)
    -- Check if we can serve stale content instead
    collapsed_forwarding_upstream_error = {
        { begin = "considering_stale_error" },
    },

    -- We need to fetch and nothing is telling us we shouldn't. Collapsed forwarding is not enabled.
    can_fetch = {
        { begin = "fetching" },
    },

    -- We've fetched and got a response status and headers. We should consider potential for ESI
    -- before doing anything else.
    response_fetched = {
        { begin = "considering_esi_scan" },
    },

    partial_response_fetched = {
        { begin = "considering_background_fetch" },
    },

    -- We had a partial response and were able to schedule a backgroud fetch for the complete
    -- resource.
    can_fetch_in_background = {
        { in_case = "partial_response_fetched", begin = "considering_esi_scan",
            but_first = "fetch_in_background" },
    },

    -- We had a partial response but skipped background fetching the complete
    -- resource, most likely because it is bigger than cache_max_memory.
    background_fetch_skipped = {
        { in_case = "partial_response_fetched", begin = "considering_esi_scan" },
    },

    -- If we went upstream and errored, check if we can serve a cached copy (stale-if-error),
    -- Publish the error first if we were the surrogate request
    upstream_error = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_upstream_error" },
        { in_case = "cache_not_accepted", begin = "serving_upstream_error" },
        { in_case = "cache_missing", begin = "serving_upstream_error" },
        { begin = "considering_stale_error" }
    },

    -- We had an error from upstream and could not serve stale content, so serve the error
    -- Or we were collapsed and the surrogate received an error but we could not serve stale
    -- in that case, try and fetch ourselves
    can_serve_upstream_error = {
        { after = "fetching", begin = "serving_upstream_error" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "fetching" },
        { begin = "serving_upstream_error" },
    },

    -- We've determined we need to scan the body for ESI.
    esi_scan_enabled = {
        { begin = "considering_gzip_inflate", but_first = "set_esi_scan_enabled" },
    },

    gzip_inflate_enabled = {
        { after = "updating_cache", begin = "preparing_response", but_first = "install_gzip_decoder" },
        { in_case = "esi_scan_enabled", begin = "updating_cache",
            but_first = { "install_gzip_decoder", "install_esi_scan_filter" } },
        { begin = "preparing_response", but_first = "install_gzip_decoder" },
    },

    gzip_inflate_disabled = {
        { after = "updating_cache", begin = "preparing_response" },
        { after = "considering_esi_scan", in_case = "esi_scan_enabled", begin = "updating_cache",
            but_first = { "install_esi_scan_filter" } },
        { in_case = "esi_process_disabled", begin = "checking_range_request" },
        { begin = "preparing_response" },
    },

    range_accepted = {
        { begin = "preparing_response", but_first = "install_range_filter" },
    },

    range_not_accepted = {
        { begin = "preparing_response" },
    },

    range_not_requested = {
        { begin = "preparing_response" },
    },

    -- We've determined no need to scan the body for ESI.
    esi_scan_disabled = {
        { begin = "updating_cache", but_first = "set_esi_scan_disabled" },
    },

    -- We deduced that the new response can cached. We always "save_to_cache". If we were fetching
    -- as a surrogate (collapsing) make sure we tell any others concerned. If we were performing
    -- a background revalidate (having served stale), we can just exit. Otherwise go back through
    -- validationg in case we can 304 to the client.
    response_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_success",
            but_first = "save_to_cache" },
        { begin = "considering_local_revalidation",
            but_first = "save_to_cache" },
    },

    -- We've deduced that the new response cannot be cached. Essentially this is as per
    -- "response_cacheable", except we "delete" rather than "save", and we don't try to revalidate.
    response_not_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_failure",
            but_first = "delete_from_cache" },
        { begin = "considering_esi_process", but_first = "delete_from_cache" },
    },

    -- A missing response body means a HEAD request or a 304 Not Modified upstream response, for
    -- example. If we were revalidating upstream, we can now re-revalidate against local cache.
    -- If we're collapsing or background revalidating, ensure we either clean up the collapsees
    -- or exit respectively.
    response_body_missing = {
        { in_case = "must_revalidate", begin = "considering_local_revalidation" } ,
        { after = "fetching_as_surrogate", begin = "publishing_collapse_failure",
            but_first = "delete_from_cache" },
        { begin = "serving",
            but_first = {
                "install_no_body_reader", "set_http_status_from_response"
            },
        },
    },

    -- We were the collapser, so digressed into being a surrogate. We're done now and have published
    -- this fact, so we pick up where it would have left off - attempting to 304 to the client.
    -- Unless we received an error, in which case check if we can serve stale instead
    published = {
        { in_case = "upstream_error", begin = "considering_stale_error" },
        { begin = "considering_local_revalidation" },
    },

    -- Client requests a max-age of 0 or stored response requires revalidation.
    must_revalidate = {
        { begin = "checking_can_fetch" },
    },

    -- We can validate locally, so do it. This doesn't imply it's valid, merely that we have
    -- the correct parameters to attempt validation.
    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    -- Standard non-conditional request.
    no_validator_present = {
        { begin = "considering_esi_process" },
    },

    -- The response has not been modified against the validators given. We'll exit 304 if we can
    -- but go via considering_esi_process in case of ESI work to be done.
    not_modified = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
    },

    -- Our cache has been modified as compared to the validators. But cache is valid, so just
    -- serve it. If we've been upstream, re-compare against client validators.
    modified = {
        { in_case = "init_worker", begin = "considering_local_revalidation" },
        { when = "revalidating_locally", begin = "considering_esi_process" },
    },

    esi_process_enabled = {
        { in_case = "can_serve_stale", begin = "serving_stale",
            but_first = {
                "install_esi_process_filter",
                "set_esi_process_enabled",
                "zero_downstream_lifetime",
                "remove_surrogate_control_header"
            }
        },
        { begin = "preparing_response",
            but_first = {
                "install_esi_process_filter",
                "set_esi_process_enabled",
                "zero_downstream_lifetime",
                "remove_surrogate_control_header"
            }
        },
    },

    esi_process_disabled = {
        { begin = "considering_gzip_inflate", but_first = "set_esi_process_disabled" },
    },

    esi_process_not_required = {
        { begin = "considering_gzip_inflate",
            but_first = { "set_esi_process_disabled", "remove_surrogate_control_header" },
        },
    },

    can_serve_disconnected = {
        { begin = "considering_esi_process", but_first = "add_disconnected_warning" },
    },

    -- We've deduced we can serve a stale version of this URI. Ensure we add a warning to the
    -- response headers.
    can_serve_stale = {
        { after = "considering_stale_error", begin = "considering_esi_process", but_first = "add_stale_warning" },
        { begin = "considering_revalidation", but_first = { "add_stale_warning" } },
    },

    -- We can serve stale, but also trigger a background revalidation
    can_serve_stale_while_revalidate = {
        { begin = "considering_esi_process", but_first = { "add_stale_warning", "revalidate_in_background" } },
    },

    -- We have a response we can use. If we've already served (we are doing background work) then
    -- just exit. If it has been prepared and we were not_modified, then set 304 and serve.
    -- If it has been prepared, set status accordingly and serve. If not, prepare it.
    response_ready = {
        { in_case = "served", begin = "exiting" },
        { in_case = "forced_cache", begin = "serving", but_first = "add_disconnected_warning"},
        -- If we might ESI, then don't 304 downstream.
        { when = "preparing_response", in_case = "esi_process_enabled",
            begin = "serving", but_first = "set_http_status_from_response" },
        { when = "preparing_response", in_case = "not_modified", after = "fetching",
            begin = "serving", but_first = {    "set_http_not_modified",
                                                "disable_output_buffers" } },
        { when = "preparing_response", in_case = "not_modified",
            begin = "serving", but_first = {    "set_http_not_modified",
                                                "install_no_body_reader" } },
        { when = "preparing_response", begin = "serving",
            but_first = "set_http_status_from_response" },
        { begin = "preparing_response" },
    },

    -- We have sent the response. If it was stale, we go back around the fetching path
    -- so that a background revalidation can occur unless the upstream errored. Otherwise exit.
    served = {
        { in_case = "upstream_error", begin = "exiting" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "exiting" },
        { in_case = "response_cacheable", begin = "exiting", but_first = "commit_transaction" },
        { begin = "exiting" },
    },

    -- When the client request is aborted clean up redis / http connections. If we're saving
    -- or have the collapse lock, then don't abort as we want to finish regardless.
    -- Note: this is a special entry point, triggered by ngx_lua client abort notification.
    aborted = {
        { in_case = "response_cacheable", begin = "cancelling_abort_request" },
        { in_case = "obtained_collapsed_forwarding_lock", begin = "cancelling_abort_request" },
        { begin = "exiting" },
    },

    -- The cache body reader was reading from the list, but the entity was collected by a worker
    -- thread because it had been replaced, and the client was too slow.
  --[[  entity_removed_during_read = {
        { begin = "exiting", but_first = "set_http_connection_timed_out" },
    },]]--

    -- Useful events for exiting with a common status. If we've already served (perhaps we're doing
    -- background work, we just exit without re-setting the status (as this errors).

    http_gateway_timeout = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_gateway_timeout" },
    },

    http_service_unavailable = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    http_internal_server_error = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_internal_server_error" },
    },
}


---------------------------------------------------------------------------------------------------
-- Pre-transitions. Actions to always perform before transitioning.
---------------------------------------------------------------------------------------------------
_M.pre_transitions = {
    exiting = { "redis_close", "httpc_close" },
    exiting_worker = { "redis_close", "httpc_close" },
    checking_cache = { "read_cache" },
    -- Never fetch with client validators, but put them back afterwards.
    fetching = {
        "remove_client_validators", "fetch", "restore_client_validators"
    },
    -- Need to save the error response before reading from cache in case we need to serve it later
    considering_stale_error = {
        "stash_error_response",
        "read_cache"
    },
    -- Restore the saved response and set the status when serving an error page
    serving_upstream_error = {
        "restore_error_response",
        "set_http_status_from_response"
    },
    serving_stale = {
        "set_http_status_from_response",
    },
    cancelling_abort_request = {
        "disable_output_buffers"
    },
}


---------------------------------------------------------------------------------------------------
-- Actions. Functions which can be called on transition.
---------------------------------------------------------------------------------------------------
_M.actions = {
    redis_close = function(self)
        return self:redis_close()
    end,

    httpc_close = function(self)
        local res = self:get_response()
        if res then
            local httpc = res.conn
            if httpc and type(httpc.set_keepalive) == "function" then
                return httpc:set_keepalive()
            end
        end
    end,

    stash_error_response = function(self)
        local error_res = self:get_response()
        self:set_response(error_res, "error")
    end,

    restore_error_response = function(self)
        local error_res = self:get_response("error")
        if error_res then
            self:set_response(error_res)
        end
    end,

    -- If ESI is enabled and we have an esi_args prefix, weed uri args
    -- beginning with the prefix (knows as ESI_ARGS) out of the URI (and thus cache key)
    -- and stash them in the custom ESI variables table.
    filter_esi_args = function(self)
        if self:config_get("esi_enabled") then
            esi.filter_esi_args(self:config_get("esi_args_prefix"))
        end
    end,

    read_cache = function(self)
        local res = self:read_from_cache()
        self:set_response(res)
    end,

    install_no_body_reader = function(self)
        local res = self:get_response()
        res.body_reader = _no_body_reader
    end,

    install_gzip_decoder = function(self)
        local res = self:get_response()
        res.header["Content-Encoding"] = nil
        res:filter_body_reader(
            "gzip_decoder",
            get_gzip_decoder(res.body_reader)
        )
    end,

    install_range_filter = function(self)
        local res = self:get_response()
        local range = self:ctx().range
        res:filter_body_reader(
            "range_request_filter",
            range:get_range_request_filter(res.body_reader)
        )
    end,

    set_esi_scan_enabled = function(self)
        local res = self:get_response()
        local ctx = self:ctx()
        ctx.esi_scan_enabled = true
        res.esi_scanned = true
    end,

    install_esi_scan_filter = function(self)
        local res = self:get_response()
        local ctx = self:ctx()
        local esi_processor = self:ctx().esi_processor
        if esi_processor then
            res:filter_body_reader(
                "esi_scan_filter",
                esi_processor:get_scan_filter(res)
            )
        end
    end,

    set_esi_scan_disabled = function(self)
        local res = self:get_response()
        self:ctx().esi_scan_disabled = true
        res.esi_scanned = false
    end,

    install_esi_process_filter = function(self)
        local res = self:get_response()
        local esi_processor = self:ctx().esi_processor
        if esi_processor then
            res:filter_body_reader(
                "esi_process_filter",
                esi_processor:get_process_filter(
                    res,
                    self:config_get("esi_pre_include_callback"),
                    self:config_get("esi_recursion_limit")
                )
            )
        end
    end,

    set_esi_process_enabled = function(self)
        self:ctx().esi_process_enabled = true
    end,

    set_esi_process_disabled = function(self)
        self:ctx().esi_process_enabled = false
    end,

    zero_downstream_lifetime = function(self)
        local res = self:get_response()
        if res.header then
            res.header["Cache-Control"] = "private, max-age=0"
        end
    end,

    remove_surrogate_control_header = function(self)
        local res = self:get_response()
        if res.header then
            res.header["Surrogate-Control"] = nil
        end
    end,

    fetch = function(self)
        local res = self:fetch_from_origin()
        if res.status ~= ngx_HTTP_NOT_MODIFIED then
            self:set_response(res)
        end
    end,

    remove_client_validators = function(self)
        -- Keep these in case we need to restore them (after revalidating upstream)
        local client_validators = self:ctx().client_validators
        client_validators["If-Modified-Since"] = ngx_var.http_if_modified_since
        client_validators["If-None-Match"] = ngx_var.http_if_none_match

        ngx_req_set_header("If-Modified-Since", nil)
        ngx_req_set_header("If-None-Match", nil)
    end,

    restore_client_validators = function(self)
        local client_validators = self:ctx().client_validators
        ngx_req_set_header("If-Modified-Since", client_validators["If-Modified-Since"])
        ngx_req_set_header("If-None-Match", client_validators["If-None-Match"])
    end,

    add_validators_from_cache = function(self)
        local cached_res = self:get_response()

        ngx_req_set_header("If-Modified-Since", cached_res.header["Last-Modified"])
        ngx_req_set_header("If-None-Match", cached_res.header["Etag"])
    end,

    add_stale_warning = function(self)
        return self:add_warning("110")
    end,

    add_transformation_warning = function(self)
        ngx_log(ngx_INFO, "adding warning")
        return self:add_warning("214")
    end,

    add_disconnected_warning = function(self)
        return self:add_warning("112")
    end,

    serve = function(self)
        return self:serve()
    end,

    set_json_response = function(self)
        local res = response.new(self.ctx(), self:cache_key_chain())
        res.header["Content-Type"] = "application/json"
        self:set_response(res)
    end,


    -- Updates the realidation_params key with data from the current request,
    -- and schedules a background revalidation job
    revalidate_in_background = function(self)
        return self:revalidate_in_background(true)
    end,

    -- Triggered on upstream partial content, assumes no stored
    -- revalidation metadata but since we have a rqeuest context (which isn't
    -- the case with `revalidate_in_background` we can simply fetch.
    fetch_in_background = function(self)
        return self:fetch_in_background()
    end,

    save_to_cache = function(self)
        local res = self:get_response()
        return self:save_to_cache(res)
    end,

    delete_from_cache = function(self)
        return self:delete_from_cache()
    end,

    release_collapse_lock = function(self)
        self:ctx().redis:del(self:cache_key_chain().fetching_lock)
    end,

    disable_output_buffers = function(self)
        self:ctx().output_buffers_enabled = false
    end,

    set_http_ok = function(self)
        ngx.status = ngx.HTTP_OK
    end,

    set_http_not_found = function(self)
        ngx.status = ngx.HTTP_NOT_FOUND
    end,

    set_http_not_modified = function(self)
        ngx.status = ngx_HTTP_NOT_MODIFIED
    end,

    set_http_service_unavailable = function(self)
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    end,

    set_http_gateway_timeout = function(self)
        ngx.status = ngx.HTTP_GATEWAY_TIMEOUT
    end,

    set_http_connection_timed_out = function(self)
        ngx.status = 524
    end,

    set_http_internal_server_error = function(self)
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    end,

    set_http_status_from_response = function(self)
        local res = self:get_response()
        if res and res.status then
            ngx.status = res.status
        else
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        end
    end,
}


---------------------------------------------------------------------------------------------------
-- Decision states.
---------------------------------------------------------------------------------------------------
-- Represented as functions which should simply make a decision, and return calling self:e(ev) with
-- the event that has occurred. Place any further logic in actions triggered by the transition
-- table.
---------------------------------------------------------------------------------------------------
_M.states = {
    connecting_to_redis = function(self)
        local rc = redis_connector.new()

        local connect_timeout = self:config_get("redis_connect_timeout")
        local read_timeout = self:config_get("redis_read_timeout")
        rc:set_connect_timeout(connect_timeout)
        rc:set_read_timeout(read_timeout)

        local redis_params = self:config_get("redis_connection")

        local redis, err = rc:connect(redis_params)
        if not redis then
            ngx_log(ngx_ERR, err)
            return self:e "redis_connection_failed"
        else
            self:ctx().redis = redis
            self:ctx().redis_params = redis_params
            return self:e "redis_connected"
        end
    end,

    connecting_to_storage = function(self)
        local storage_params = self:config_get("storage_connection")

        -- TODO: For now we assume redis. The plan is to make the schema drive different backends.
        local storage = require("ledge.storage.redis").new(self:ctx())
        storage.body_max_memory = self:config_get("cache_max_memory")

        local ok, err = storage:connect(storage_params)
        if not ok then
            ngx_log(ngx_ERR, err)
            return self:e "storage_connection_failed"
        else
            self:ctx().storage = storage
            return self:e "storage_connected"
        end
    end,

    sleeping = function(self)
        local last_sleep = self:ctx().last_sleep or 0
        local sleep = last_sleep + 5
        ngx_log(ngx_ERR, "sleeping for ", sleep, "s before reconnecting...")
        ngx_sleep(sleep)
        self:ctx().last_sleep = sleep
        return self:e "woken"
    end,

    checking_method = function(self)
        local method = ngx_req_get_method()
        if method == "PURGE" then
            return self:e "purge_requested"
        elseif method ~= "GET" and method ~= "HEAD" then
            -- Only GET/HEAD are cacheable
            return self:e "cache_not_accepted"
        else
            return self:e "cacheable_method"
        end
    end,

    considering_wildcard_purge = function(self)
        local key_chain = self:cache_key_chain()
        if ngx_re_find(key_chain.root, "\\*", "soj") then
            return self:e "wildcard_purge_requested"
        else
            return self:e "purge_requested"
        end
    end,

    checking_origin_mode = function(self)
        -- Ignore the client requirements if we're not in "NORMAL" mode.
        if self:config_get("origin_mode") < _M.ORIGIN_MODE_NORMAL then
            return self:e "forced_cache"
        else
            return self:e "cacheable_method"
        end
    end,

    accept_cache = function(self)
        return self:e "cache_accepted"
    end,

    checking_request = function(self)
        if self:request_accepts_cache() then
            return self:e "cache_accepted"
        else
            return self:e "cache_not_accepted"
        end
    end,

    checking_cache = function(self)
        local res = self:get_response()

        if not res then
            return self:e "cache_missing"
        elseif res:has_expired() then
            return self:e "cache_expired"
        else
            return self:e "cache_valid"
        end
    end,

    considering_gzip_inflate = function(self)
        local res = self:get_response()
        local accept_encoding = ngx_req_get_headers()["Accept-Encoding"] or ""

        -- If the response is gzip encoded and the client doesn't support it, then inflate
        if res.header["Content-Encoding"] == "gzip" then
            local accepts_gzip = h_util.header_has_directive(accept_encoding, "gzip")

            if self:ctx().esi_scan_enabled or
                (self:config_get("gunzip_enabled") and accepts_gzip == false) then
                return self:e "gzip_inflate_enabled"
            end
        end

        return self:e "gzip_inflate_disabled"
    end,

    considering_esi_scan = function(self)
        if self:config_get("esi_enabled") == true then
            local res = self:get_response()
            if not res.has_body then
                return self:e "esi_scan_disabled"
            end

            -- Choose an ESI processor from the Surrogate-Control header
            -- (Currently there is only the ESI/1.0 processor)
            local processor = esi.choose_esi_processor(res)
            if processor then
                if esi.is_allowed_content_type(res, self:config_get("esi_content_types")) then
                    -- Store parser for processing
                    -- TODO: Strictly this should be installed by the state machine
                    self:ctx().esi_processor = processor
                    return self:e "esi_scan_enabled"
                end
            end
        end

        return self:e "esi_scan_disabled"
    end,

    -- We decide to process if:
    --  - We know the response has_esi (fast path)
    --  - We already decided to scan for esi (slow path)
    --  - We aren't delegating responsibility downstream, which would occur when both:
    --      - Surrogate-Capability is set with a matching parser type and version.
    --      - Delegation is enabled in configuration.
    --
    --  So essentially, if we think we may need to process, then we do. We don't want to
    --  accidentally send ESI instructions to a client, so we only delegate if we're sure.
    considering_esi_process = function(self)
        local res = self:get_response()

        -- If we know there's no esi or it hasn't been scanned, don't process
        if not res.has_esi and res.esi_scanned == false then
            return self:e "esi_process_disabled"
        end

        if not self:ctx().esi_processor then
            -- On the fast path with ESI already detected, the processor wont have been loaded
            -- yet, so we must do that now
            -- TODO: Perhaps the state machine can load the processor to avoid this weird check
            -- TODO: Should res.has_esi be esi_processor_token. Would help with chunk.has_esi ambiguity.
            if res.has_esi then
                self:ctx().esi_processor = esi.choose_esi_processor(res)
            else
                -- We know there's nothing to do
                return self:e "esi_process_not_required"
            end
        end

        if esi.can_delegate_to_surrogate(
            self:config_get("esi_allow_surrogate_delegation"),
            self:ctx().esi_processor.token
        ) then
            -- Disabled due to surrogate delegation
            return self:e "esi_process_disabled"
        else
            return self:e "esi_process_enabled"
        end
    end,

    checking_range_request = function(self)
        local res = self:get_response()

        local range = range.new()
        local res, partial_response = range:handle_range_request(res)
        self:ctx().range = range

        self:set_response(res)

        if partial_response then
            return self:e "range_accepted"
        elseif partial_response == false then
            return self:e "range_not_accepted"
        else
            return self:e "range_not_requested"
        end
    end,

    checking_can_fetch = function(self)
        if self:config_get("origin_mode") == _M.ORIGIN_MODE_BYPASS then
           return self:e "http_service_unavailable"
        end

        if h_util.header_has_directive(
            ngx_req_get_headers()["Cache-Control"], "only-if-cached"
        ) then
            return self:e "http_gateway_timeout"
        end

        if self:config_get("enable_collapsed_forwarding") then
            return self:e "can_fetch_but_try_collapse"
        end

        return self:e "can_fetch"
    end,

    requesting_collapse_lock = function(self)
        local redis = self:ctx().redis
        local key_chain = self:cache_key_chain()
        local lock_key = key_chain.fetching_lock

        local timeout = tonumber(self:config_get("collapsed_forwarding_window"))
        if not timeout then
            ngx_log(ngx_ERR, "collapsed_forwarding_window must be a number")
            return self:e "collapsed_forwarding_failed"
        end

        -- Watch the lock key before we attempt to lock. If we fail to lock, we need to subscribe
        -- for updates, but there's a chance we might miss the message.
        -- This "watch" allows us to abort the "subscribe" transaction if we've missed
        -- the opportunity.
        --
        -- We must unwatch later for paths without transactions, else subsequent transactions
        -- on this connection could fail.
        redis:watch(lock_key)

        local res, err = self:acquire_lock(lock_key, timeout)

        if res == nil then -- Lua script failed
            redis:unwatch()
            ngx_log(ngx_ERR, err)
            return self:e "collapsed_forwarding_failed"
        elseif res then -- We have the lock
            redis:unwatch()
            return self:e "obtained_collapsed_forwarding_lock"
        else -- Lock is busy
            redis:multi()
            redis:subscribe(key_chain.root)
            if redis:exec() ~= ngx_null then -- We subscribed before the lock was freed
                return self:e "subscribed_to_collapsed_forwarding_channel"
            else -- Lock was freed before we subscribed
                return self:e "collapsed_forwarding_channel_closed"
            end
        end
    end,

    publishing_collapse_success = function(self)
        local redis = self:ctx().redis
        local key_chain = self:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_response_ready")
        return self:e "published"
    end,

    publishing_collapse_failure = function(self)
        local redis = self:ctx().redis
        local key_chain = self:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_forwarding_failed")
        return self:e "published"
    end,

    publishing_collapse_upstream_error = function(self)
        local redis = self:ctx().redis
        local key_chain = self:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_forwarding_upstream_error")
        return self:e "published"
    end,

    fetching_as_surrogate = function(self)
        return self:e "can_fetch"
    end,

    waiting_on_collapsed_forwarding_channel = function(self)
        local redis = self:ctx().redis

        -- Extend the timeout to the size of the window
        redis:set_timeout(self:config_get("collapsed_forwarding_window"))
        local res, err = redis:read_reply() -- block until we hear something or timeout
        if not res then
            return self:e "http_gateway_timeout"
        else
            redis:set_timeout(self:config_get("redis_read_timeout"))
            redis:unsubscribe()

            -- This is overly explicit for the sake of state machine introspection. That is
            -- we never call self:e() without a literal event string.
            if res[3] == "collapsed_response_ready" then
                return self:e "collapsed_response_ready"
            elseif res[3] == "collapsed_forwarding_upstream_error" then
                return self:e "collapsed_forwarding_upstream_error"
            else
                return self:e "collapsed_forwarding_failed"
            end
        end
    end,

    fetching = function(self)
        local res = self:get_response()

        if res.status >= 500 then
            return self:e "upstream_error"
        elseif res.status == ngx.HTTP_NOT_MODIFIED then
            return self:e "response_ready"
        elseif res.status == ngx_PARTIAL_CONTENT then
            return self:e "partial_response_fetched"
        else
            return self:e "response_fetched"
        end
    end,

    considering_background_fetch = function(self)
        local res = self:get_response()
        if res.status ~= ngx_PARTIAL_CONTENT then
            -- Shouldn't happen, but just in case
            return self:e "background_fetch_skipped"
        else
            local content_range = res.header["Content-Range"]
            if content_range then
                local m, err = ngx_re_match(
                    content_range,
                    [[bytes\s+(?:\d+|\*)-(?:\d+|\*)/(\d+)]],
                    "oj"
                )

                if m then
                    local size = tonumber(m[1])
                    local max_memory = self:config_get("cache_max_memory")
                    if max_memory * 1024 > size then
                        return self:e "can_fetch_in_background"
                    end
                end
            end

            return self:e "background_fetch_skipped"
        end
    end,

    purging = function(self)
        if self:purge(_purge_mode()) then
            return self:e "purged"
        else
            return self:e "nothing_to_purge"
        end
    end,

    wildcard_purging = function(self)
        self:purge_in_background()
        return self:e "wildcard_purge_scheduled"
    end,

    considering_stale_error = function(self)
        if self:can_serve_stale_if_error() then
            return self:e "can_serve_disconnected"
        else
            return self:e "can_serve_upstream_error"
        end
    end,

    serving_upstream_error = function(self)
        self:serve()
        return self:e "served"
    end,

    considering_revalidation = function(self)
        if self:must_revalidate() then
            return self:e "must_revalidate"
        elseif self:can_revalidate_locally() then
            return self:e "can_revalidate_locally"
        else
            return self:e "no_validator_present"
        end
    end,

    considering_local_revalidation = function(self)
        if self:can_revalidate_locally() then
            return self:e "can_revalidate_locally"
        else
            return self:e "no_validator_present"
        end
    end,

    revalidating_locally = function(self)
        if self:is_valid_locally() then
            return self:e "not_modified"
        else
            return self:e "modified"
        end
    end,

    checking_can_serve_stale = function(self)
        if self:config_get("origin_mode") < self.ORIGIN_MODE_NORMAL then
            return self:e "can_serve_stale"
        elseif self:can_serve_stale_while_revalidate() then
            return self:e "can_serve_stale_while_revalidate"
        elseif self:can_serve_stale() then
            return self:e "can_serve_stale"
        else
            return self:e "cache_expired"
        end
    end,

    updating_cache = function(self)
        local res = self:get_response()
        if res.has_body then
            if res:is_cacheable() then
                return self:e "response_cacheable"
            else
                return self:e "response_not_cacheable"
            end
        else
            return self:e "response_body_missing"
        end
    end,

    preparing_response = function(self)
        return self:e "response_ready"
    end,

    serving = function(self)
        self:serve()
        return self:e "served"
    end,

    serving_stale = function(self)
        self:serve()
        return self:e "served"
    end,

    exiting = function(self)
        ngx.exit(ngx.status)
    end,

    running_worker = function(self)
        return true
    end,

    exiting_worker = function(self)
        return true
    end,

    cancelling_abort_request = function(self)
        return true
    end,
}


-- Transition to a new state.
function _M.t(self, state)
    local ctx = self:ctx()

    -- Check for any transition pre-tasks
    local pre_t = self.pre_transitions[state]

    if pre_t then
        for _,action in ipairs(pre_t) do
            if _M.DEBUG then ngx_log(ngx_DEBUG, "#a: ", action) end
            self.actions[action](self)
        end
    end

    if _M.DEBUG then ngx_log(ngx_DEBUG, "#t: ", state) end

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


-- Process state transitions and actions based on the event fired.
function _M.e(self, event)
    if _M.DEBUG then ngx_log(ngx_DEBUG, "#e: ", event) end

    local ctx = self:ctx()
    ctx.event_history[event] = true

    -- It's possible for states to call undefined events at run time. Try to handle this nicely.
    if not self.events[event] then
        ngx_log(ngx.CRIT, event, " is not defined.")
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        self:t("exiting")
    end

    for _, trans in ipairs(self.events[event]) do
        local t_when = trans["when"]
        if t_when == nil or t_when == ctx.current_state then
            local t_after = trans["after"]
            if not t_after or ctx.state_history[t_after] then
                local t_in_case = trans["in_case"]
                if not t_in_case or ctx.event_history[t_in_case] then
                    local t_but_first = trans["but_first"]
                    if t_but_first then
                        if type(t_but_first) == "table" then
                            for _,action in ipairs(t_but_first) do
                                if _M.DEBUG then ngx_log(ngx_DEBUG, "#a: ", action) end
                                self.actions[action](self)
                            end
                        else
                            if _M.DEBUG then ngx_log(ngx_DEBUG, "#a: ", t_but_first) end
                            self.actions[t_but_first](self)
                        end
                    end

                    return self:t(trans["begin"])
                end
            end
        end
    end
end


function _M.read_from_cache(self)
    local ctx = self:ctx()

    local res = response.new(ctx, self:cache_key_chain())
    local ok, err = res:read()
    if not ok then
        if err then
            return self:e "http_internal_server_error"
        else
            return nil
        end
    end

    local storage = ctx.storage
    if not storage:exists(res.entity_id) then
        ngx.log(ngx.DEBUG, res.entity_id, " doesn't exist in storage")
        -- Should exist, so presumed evicted

        local delay = self:gc_wait(res.size)
        self:put_background_job("ledge", "ledge.jobs.collect_entity", {
            entity_id = res.entity_id,
        }, {
            delay = res.size,
            tags = { "collect_entity" },
            priority = 10,
        })
        return nil -- MISS
    end

    res:filter_body_reader("cache_body_reader", storage:get_reader(res))

    self:emit("cache_accessed", res)
    return res
end


-- Fetches a resource from the origin server.
function _M.fetch_from_origin(self)
    local res = response.new(self:ctx(), self:cache_key_chain())
    self:emit("origin_required")

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
        path = self:relative_uri(),
        body = client_body_reader,
        headers = headers,
    }

    -- allow request params to be customised
    self:emit("before_request", req_params)

    local origin, err = httpc:request(req_params)

    if not origin then
        ngx_log(ngx_ERR, err)
        res.status = 524
        return res
    end

    res.status = origin.status

    -- Merge end-to-end headers
    for k,v in pairs(origin.headers) do
        if not HOP_BY_HOP_HEADERS[str_lower(k)] then
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
    self:emit("origin_fetched", res)

    return res
end


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

    self:emit("before_save_revalidation_data", reval_params, reval_headers)

    return reval_params, reval_headers
end


function _M.revalidate_in_background(self, update_revalidation_data)
    local redis = self:ctx().redis
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
        jid = ngx_md5("revalidate:" .. self:full_uri()),
        tags = { "revalidate" },
        priority = 4,
    })
end


function _M.save_to_cache(self, res)
    self:emit("before_save", res)

    -- Length is only set if there was a Content-Length header
    local length = res.length
    local max_memory = (self:config_get("cache_max_memory") or 0) * 1024
    if length and length > max_memory then
        -- We'll carry on serving, just not saving.
        return nil, "advertised length is greated than cache_max_memory"
    end


    -- Watch the main key pointer. We abort the transaction if another request
    -- updates this key before we finish.
    local key_chain = self:cache_key_chain()
    local redis = self:ctx().redis
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
        -- TODO: This will happen regardless of transaction failure
        self:put_background_job("ledge", "ledge.jobs.collect_entity", {
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

    res.uri = self:full_uri()
    local ok, err = res:save(keep_cache_for)

    -- Set revalidation parameters from this request
    local reval_params, reval_headers = self:revalidation_data()
    redis:del(key_chain.reval_params)
    redis:hmset(key_chain.reval_params, reval_params)
    redis:del(key_chain.reval_req_headers)
    redis:hmset(key_chain.reval_req_headers, reval_headers)

    local ok, err
    ok, err = redis:expire(key_chain.reval_params, keep_cache_for)
    if not ok then ngx_log(ngx_ERR, err) end

    ok, err = redis:expire(key_chain.reval_req_headers, keep_cache_for)
    if not ok then ngx_log(ngx_ERR, err) end

    if res.has_body then
        local storage = self:ctx().storage
        res:filter_body_reader(
            "cache_body_writer",
            storage:get_writer(res, keep_cache_for)
        )
    else
        -- Run transaction
        if redis:exec() == ngx_null then
            ngx_log(ngx_ERR, "Failed to save cache item")
        end
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
    local redis = self:ctx().redis
    local key_chain = self:cache_key_chain()

    local entity_id = self:entity_id(key_chain)

    if entity_id then
        local size = redis:hget(key_chain.main, "size")
        self:put_background_job("ledge", "ledge.jobs.collect_entity", {
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


-- Purges the cache item according to X-Purge instructions, which defaults to "invalidate".
-- If there's nothing to do we return false which results in a 404.
function _M.purge(self, purge_mode)
    local redis = self:ctx().redis
    local key_chain = self:cache_key_chain()
    local entity_id, err = redis:hget(key_chain.main, "entity")
    local storage = self:ctx().storage

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


function _M.purge_in_background(self)
    local key_chain = self:cache_key_chain()
    local purge_mode = _purge_mode()

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
    local redis = self:ctx().redis
    local storage = self:ctx().storage

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

        storage:expire(entity_id, ttl - ttl_reduction)

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
        local visible_hostname = self:visible_hostname()

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
        local ctx = self:ctx()
        local state_history = ctx.state_history
        local event_history = ctx.event_history

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

        self:emit("response_ready", res)

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        local cjson = require "cjson"
        ngx.log(ngx.DEBUG, "Headers at serve: ", cjson.encode(res.header))

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
    local ctx = self:ctx()

    repeat
        local chunk, err = reader(buffer_size)
        if chunk and ctx.output_buffers_enabled then
            local ok, err = ngx_print(chunk)
            if not ok then ngx_log(ngx_ERR, err) end

            -- Flush each full buffer, if we can
            buffered = buffered + #chunk
            if can_flush and buffered >= buffer_size then
                local ok, err = ngx_flush(true)
                if not ok then ngx_log(ngx_ERR, err) end

                buffered = 0
            end
        end

    until not chunk
end


return _M
