local cjson = require "cjson"
local http = require "resty.http"
local resolver = require "resty.dns.resolver"
local qless = require "resty.qless"
local response = require "ledge.response"
local h_util = require "ledge.header_util"
local ffi = require "ffi"

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
local ngx_get_phase = ngx.get_phase
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_req_get_method = ngx.req.get_method
local ngx_req_raw_header = ngx.req.raw_header
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
local ngx_PARTIAL_CONTENT = 206
local ngx_RANGE_NOT_SATISFIABLE = 416
local tbl_insert = table.insert
local tbl_concat = table.concat
local tbl_remove = table.remove
local tbl_getn = table.getn
local tbl_sort = table.sort
local str_lower = string.lower
local str_sub = string.sub
local str_match = string.match
local str_gmatch = string.gmatch
local str_find = string.find
local str_lower = string.lower
local str_len = string.len
local math_floor = math.floor
local math_ceil = math.ceil
local co_wrap = coroutine.wrap
local co_yield = coroutine.yield
local cjson_encode = cjson.encode
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C


ffi_cdef[[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
]]


local function random_hex(len)
    local len = math_floor(len / 2)

    local bytes = ffi_new("uint8_t[?]", len)
    C.RAND_pseudo_bytes(bytes, len)
    if not bytes then 
        ngx_log(ngx_ERR, "error getting random bytes via FFI")
        return nil
    end

    local hex = ffi_new("uint8_t[?]", len * 2)
    C.ngx_hex_dump(hex, bytes, len)
    return ffi_string(hex, len * 2)
end


local function str_split(str, delim)
    if not str or not delim then return nil end
    local it, err = str_gmatch(str, "([^"..delim.."]+)")
    if it then
        local output = {}
        while true do
            local m, err = it()
            if not m then
                break
            end
            tbl_insert(output, m)
        end
        return output
    end
end


local _M = {
    _VERSION = '0.14',

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

        buffer_size = 2^17, -- 131072 (bytes) (128KB) Internal buffer size for data read/written/served.
        cache_max_memory = 2048, -- (KB) Max size for a cache item before we bail on trying to store.

        redis_database  = 0,
        redis_qless_database = 1,
        redis_connect_timeout = 500,    -- (ms) Connect timeout
        redis_read_timeout = 5000,      -- (ms) Read/write timeout
        redis_keepalive_timeout = nil,  -- (sec) Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- (sec) Defaults to 30 or lua_socket_pool_size
        redis_host = { host = "127.0.0.1", port = 6379, socket = nil, password = nil },

        redis_use_sentinel = false,
        redis_sentinel_master_name = "mymaster",
        redis_sentinels = {
            -- e.g.
            -- { host = "127.0.0.1", port = 6381 },
            -- { host = "127.0.0.1", port = 6382 },
            -- { host = "127.0.0.1", port = 6383 },
        },

        keep_cache_for  = 86400 * 30,   -- (sec) Max time to keep cache items past expiry + stale.
                                        -- Items will be evicted when under memory pressure, so this
                                        -- setting is just about trying to keep cache around to serve 
                                        -- stale in the event of origin disconnection.

        minimum_old_entity_download_rate = 56,  -- (kbps). Slower clients than this unfortunate enough
                                                -- to be reading from replaced (in memory) entities will 
                                                -- have their entity garbage collected before they finish.

        max_stale       = nil,  -- (sec) Overrides how long cache will continue be served 
                                -- for beyond the TTL. This violates the spec, and adds a warning header.
        stale_if_error  = nil,  -- (sec) Overrides how long to serve stale on upstream error.

        esi_enabled      = false,
        esi_content_types = { "text/html" },
        esi_allow_surrogate_delegation = false, -- Set to true to delegate to any downstream host
                                                -- that sets the Surrogate-Capability header, or to
                                                -- a table of IP addresses to limit to. e.g.
                                                -- { "1.2.3.4", "5.6.7.8" }

        enable_collapsed_forwarding = false,
        collapsed_forwarding_window = 60 * 1000, -- Window for collapsed requests (ms)
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
        return self.config[param]
    else
        return p
    end
end


function _M.handle_abort(self)
    -- Use a closure to pass through the ledge instance
    return function()
        self:e "aborted"
    end
end


function _M.bind(self, event, callback)
    local events = self:ctx().events
    if not events[event] then events[event] = {} end
    tbl_insert(events[event], callback)
end


function _M.emit(self, event, res)
    local events = self:ctx().events
    for _, handler in ipairs(events[event] or {}) do
        if type(handler) == "function" then
            handler(res)
        end
    end
end


function _M.run(self)
    local set, msg = ngx.on_abort(self:handle_abort())
    if set == nil then
       ngx_log(ngx_WARN, "on_abort handler not set: "..msg)
    end
    self:e "init"
end


function _M.run_workers(self, options)
    if not options then options = {} end
    local resty_qless_worker = require "resty.qless.worker"

    local redis_params

    if self:config_get("redis_use_sentinel") then
        redis_params = {
            sentinel = {
                hosts = self:config_get("redis_sentinels"),
                master_name = self:config_get("redis_sentinel_master_name"),
            }
        }
    else
        redis_params = {
            redis = self:config_get("redis_host")
        }
    end

    local connection_options = {
        connect_timeout = self:config_get("redis_connect_timeout"),
        read_timeout = self:config_get("redis_read_timeout"),
        database = self:config_get("redis_qless_database"),
    }

    local worker = resty_qless_worker.new(redis_params, connection_options)

    worker.middleware = function(job)
        self:e "init_worker"
        job.redis = self:ctx().redis

        co_yield() -- Perform the job

        self:e "worker_finished"
    end

    worker:start({
        interval = options.interval or 10,
        concurrency = options.concurrency or 1,
        reserver = "ordered",
        queues = { "ledge" },
    })
end


function _M.relative_uri(self)
    return ngx_var.uri .. ngx_var.is_args .. (ngx_var.query_string or "")
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


function _M.accepts_stale(self, res)
    -- Check response for headers that prevent serving stale
    local res_cc = res.header["Cache-Control"]
    if h_util.header_has_directive(res_cc, 'revalidate') or
        h_util.header_has_directive(res_cc, 's-maxage') then
        return nil
    end

    -- Check for max-stale request header
    local req_cc = ngx_req_get_headers()['Cache-Control']
    local req_max_stale = h_util.get_numeric_header_token(req_cc, 'max-stale')
    if req_max_stale then
        return req_max_stale
    end
    
    -- Fall back to max_stale config
    local max_stale = self:config_get("max_stale")
    if max_stale and max_stale > 0 then
        return max_stale
    end
end


function _M.calculate_stale_ttl(self)
    local res = self:get_response()
    local stale = self:accepts_stale(res) or 0
    local min_fresh = h_util.get_numeric_header_token(
        ngx_req_get_headers()['Cache-Control'],
        'min-fresh'
    ) or 0

    return (res.remaining_ttl - min_fresh) + stale
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


-- returns a table of ranges, or nil
--
-- e.g.
-- {
--      { from = 0, to = 99 }, 
--      { from = 100, to = 199 },
-- }
function _M.request_byte_range(self)
    local bytes = h_util.get_header_token(ngx_req_get_headers().range, "bytes")
    local ranges = nil

    if bytes then
        ranges = str_split(bytes, ",")
        if not ranges then ranges = { bytes } end
        for i,r in ipairs(ranges) do
            local from, to = str_match(r, "(%d*)%-(%d*)")
            ranges[i] = { from = tonumber(from), to = tonumber(to) }
        end
    end

    return ranges
end


local function sort_byte_ranges(first, second)
    if not first.from or not second.from then
        ngx_log(ngx_ERROR, "Attempt to compare invalid byteranges")
        return true
    end
    return first.from <= second.from
end


function _M.must_revalidate(self)
    local cc = ngx_req_get_headers()["Cache-Control"]
    if cc == "max-age=0" then
        return true
    else
        local res = self:get_response()
        local res_age = res.header["Age"]

        if h_util.header_has_directive(res.header["Cache-Control"], "revalidate") then
            return true
        elseif type(cc) == "string" and res_age then
            local max_age = cc:match("max%-age=(%d+)")
            if max_age and res_age > tonumber(max_age) then
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
            if res_lm_parsed > req_ims_parsed then
                return false
            end
        end
    end

    if res.header["Etag"] and req_h["If-None-Match"] then
        if res.header["Etag"] ~= req_h["If-None-Match"] then
            return false
        end
    end

    return true
end


function _M.set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end


function _M.get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


function _M.cache_key(self)
    if not self:ctx().cache_key then
        -- Generate the cache key. The default spec is:
        -- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
        local key_spec = self:config_get("cache_key_spec") or {
            ngx_var.scheme,
            ngx_var.host,
            ngx_var.uri,
            ngx_var.args or "",
        }
        tbl_insert(key_spec, 1, "cache_obj")
        tbl_insert(key_spec, 1, "ledge")
        self:ctx().cache_key = tbl_concat(key_spec, ":")
    end
    return self:ctx().cache_key
end


function _M.cache_entity_keys(self, cache_key)
    local redis = self:ctx().redis
    local entity = redis:get(cache_key)

    if not entity or entity == ngx_null then -- MISS
        return nil
    end
    
    local keys = self:entity_keys(cache_key .. ":" .. entity)

    for k, v in pairs(keys) do
        local res = redis:exists(v)
        if not res or res == ngx_null or res == 0 then return nil end
    end

    return keys
end


function _M.entity_keys(self, entity_key)
    return  {
        main = entity_key,
        headers = entity_key .. ":headers",
        body = entity_key .. ":body",
        body_esi = entity_key .. ":body_esi",
    }
end


function _M.fetching_key(self)
    return self:cache_key() .. ":fetching"
end


function _M.accepts_stale_error(self)
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local stale_age = self:config_get("stale_if_error")

    local res = self:get_response()
    if not res then return false end

    if h_util.header_has_directive(req_cc, "stale-if-error") then
        stale_age = h_util.get_numeric_header_token(req_cc, "stale-if-error")
    end

    if not stale_age then
        return false 
    else
        return ((res.remaining_ttl + stale_age) > 0)
    end
end


function _M.put_background_job(self, queue, klass, data, options)
    local redis = self:ctx().redis
    local qless_db = self:config_get("redis_qless_database") or 1
    redis:select(qless_db)

    -- Place this job on the queue
    local q = qless.new({ redis_client = redis })
    q.queues[queue]:put(klass, data, options)

    redis:select(self:config_get("redis_database") or 0)
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

    -- We're connected! Let's get on with it then... First step, analyse the request.
    -- If we're a worker then we just start running tasks.
    redis_connected = {
        { in_case = "init_worker", begin = "running_worker" },
        { begin = "checking_method" },
    },

    cacheable_method = {
        { when = "checking_origin_mode", begin = "checking_request" },
        { begin = "checking_origin_mode" },
    },

    -- PURGE method detected.
    purge_requested = {
        { begin = "purging" },
    },

    -- Succesfully purged (expired) a cache entry. Exit 200 OK.
    purged = {
        { begin = "exiting", but_first = "set_http_ok" },
    },

    -- URI to purge was not found. Exit 404 Not Found.
    nothing_to_purge = {
        { begin = "exiting", but_first = "set_http_not_found" },
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
    },

    -- We have a (not expired) cache entry. Lets try and validate in case we can exit 304.
    cache_valid = {
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
        { begin = "considering_esi_scan", but_first = "revalidate_in_background" },
    },

    -- If we went upstream and errored, check if we can serve a cached copy (stale-if-error),
    -- Publish the error first if we were the surrogate request
    upstream_error = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_upstream_error" },
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
        { begin = "updating_cache", but_first = "set_esi_scan_enabled" },
    },

    -- We've determined no need to scan the body for ESI.
    esi_scan_disabled = {
        { begin = "updating_cache" },
    },

    -- We deduced that the new response can cached. We always "save_to_cache". If we were fetching
    -- as a surrogate (collapsing) make sure we tell any others concerned. If we were performing
    -- a background revalidate (having served stale), we can just exit. Otherwise go back through
    -- validationg in case we can 304 to the client.
    response_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_success", 
            but_first = "save_to_cache" },
        { after = "revalidating_in_background", begin = "exiting", 
            but_first = "save_to_cache" },
        { begin = "considering_local_revalidation", 
            but_first = "save_to_cache" },
    },

    -- We've deduced that the new response cannot be cached. Essentially this is as per
    -- "response_cacheable", except we "delete" rather than "save", and we don't try to revalidate.
    response_not_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_failure",
            but_first = "delete_from_cache" },
        { after = "revalidating_in_background", begin = "exiting", 
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
        { after = "revalidating_in_background", begin = "exiting" },
        { begin = "serving" },
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
        --{ begin = "revalidating_upstream" },
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
        { when = "revalidating_upstream", begin = "considering_local_revalidation" },
    },

    esi_process_enabled = {
        { begin = "preparing_response", 
            but_first = { "set_esi_process_enabled", "zero_downstream_lifetime"} },
    },

    esi_process_disabled = {
        { begin = "preparing_response", but_first = "set_esi_process_disabled" },
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
        { when = "preparing_response", in_case = "not_modified",
            begin = "serving", but_first = "set_http_not_modified" },
        { when = "preparing_response", begin = "serving", 
            but_first = "set_http_status_from_response" },
        { begin = "preparing_response" },
    },

    -- We've deduced we can serve a stale version of this URI. Ensure we add a warning to the
    -- response headers.
    -- TODO: "serve_stale" isn't really an event?
    serve_stale = {
        { begin = "serving_stale", but_first = { "add_stale_warning", "revalidate_in_background" } },
    },

    -- We have sent the response. If it was stale, we go back around the fetching path
    -- so that a background revalidation can occur unless the upstream errored. Otherwise exit.
    served = {
        { in_case = "upstream_error", begin = "exiting" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "exiting" },
        { begin = "exiting" },
    },

    -- When the client request is aborted clean up redis / http connections. If we're saving
    -- or have the collapse lock, then don't abort as we want to finish regardless.
    -- Note: this is a special entry point, triggered by ngx_lua client abort notification.
    aborted = {
        { in_case = "response_cacheable", begin = "cancelling_abort_request" },
        { in_case = "obtained_collapsed_forwarding_lock", begin = "cancelling_abort_request" },
        { begin = "exiting", but_first = "set_http_client_abort" },
    },

    -- The cache body reader was reading from the list, but the entity was collected by a worker
    -- thread because it had been replaced, and the client was too slow.
    entity_removed_during_read = {
        { begin = "exiting", but_first = "set_http_connection_timed_out" },
    },

    -- Useful events for exiting with a common status. If we've already served (perhaps we're doing
    -- background work, we just exit without re-setting the status (as this errors).

    http_ok = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_ok" },
    },

    http_not_found = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_not_found" },
    },

    http_gateway_timeout = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_gateway_timeout" },
    },

    http_service_unavailable = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
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
    -- Use validators from cache when revalidating upstream, and restore client validators
    -- afterwards.
    revalidating_upstream = {
        "remove_client_validators",
        "add_validators_from_cache",
        "fetch",
        "restore_client_validators"
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
}


---------------------------------------------------------------------------------------------------
-- Actions. Functions which can be called on transition.
---------------------------------------------------------------------------------------------------
_M.actions = {
    redis_connect = function(self)
        return self:redis_connect()
    end,

    redis_close = function(self)
        return self:redis_close()
    end,

    httpc_close = function(self)
        local res = self:get_response()
        if res then
            local httpc = res.conn
            if httpc then
                return httpc:set_keepalive()
            end
        end
    end,

    stash_error_response = function(self)
        local error_res = self:get_response()
        self:set_response(error_res, "error")
    end,
    
    restore_error_response = function(self)
        local error_res = self:get_response('error')
        self:set_response(error_res)
    end,

    read_cache = function(self)
        local res = self:read_from_cache() 
        self:set_response(res)
    end,

    set_esi_scan_enabled = function(self)
        self:ctx().esi_scan_enabled = true
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
            res.header["Cache-Control"] = "private, must-revalidate"
        end
    end,

    fetch = function(self)
        local res = self:fetch_from_origin()
        if res.status ~= ngx.HTTP_NOT_MODIFIED then
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

        -- TODO: Patch OpenResty to accept additional headers for subrequests.
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

    revalidate_in_background = function(self)
        self:put_background_job("ledge", "ledge.jobs.revalidate", {
            raw_header = ngx_req_raw_header(),
            host = ngx_var.host,
            server_addr = ngx_var.server_addr,
            server_port = ngx_var.server_port,
        })
    end,

    save_to_cache = function(self)
        local res = self:get_response()
        return self:save_to_cache(res)
    end,

    delete_from_cache = function(self)
        return self:delete_from_cache()
    end,

    release_collapse_lock = function(self)
        self:ctx().redis:del(self:fetching_key())
    end,

    set_http_ok = function(self)
        ngx.status = ngx.HTTP_OK
    end,

    set_http_not_found = function(self)
        ngx.status = ngx.HTTP_NOT_FOUND
    end,

    set_http_not_modified = function(self)
        ngx.status = ngx.HTTP_NOT_MODIFIED
    end,

    set_http_service_unavailable = function(self)
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    end,

    set_http_gateway_timeout = function(self)
        ngx.status = ngx.HTTP_GATEWAY_TIMEOUT
    end,

    set_http_client_abort = function(self)
        ngx.status = 499 -- No ngx constant for client aborted
    end,
    
    set_http_connection_timed_out = function(self)
        ngx.status = 524
    end,

    set_http_status_from_response = function(self)
        local res = self:get_response()
        if res.status then
            ngx.status = res.status
        else
            res.status = ngx.HTTP_INTERNAL_SERVER_ERROR
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
        local redis_params

        if self:config_get("redis_use_sentinel") then
            redis_params = {
                sentinel = {
                    hosts = self:config_get("redis_sentinels"),
                    master_name = self:config_get("redis_sentinel_master_name"),
                    try_slaves = true,
                }
            }
        else
            redis_params = {
                redis = self:config_get("redis_host"),
            }
        end

        local connection_options = {
            connect_timeout = self:config_get("redis_connect_timeout"),
            read_timeout = self:config_get("redis_read_timeout"),
            database = self:config_get("redis_database"),
        }

        local redis, err = redis_connector.connect(redis_params, connection_options)
        if not redis then
            ngx_log(ngx_ERR, err)
            return self:e "redis_connection_failed"
        else
            self:ctx().redis = redis
            return self:e "redis_connected"
        end
    end,

    selecting_redis_master = function(self)
        local sentinel = self:ctx().sentinel
        local res, err = sentinel:sentinel(
            "get-master-addr-by-name",
            self:config_get("redis_sentinel_master_name")
         )
         if res and res ~= ngx_null and res[1] and res[2] then
             self:config_set("redis_hosts", {
                 { host = res[1], port = res[2] },
             })

             return self:e "redis_master_selected"
         else
             return self:e "redis_selection_failed"
         end
    end,

    selecting_redis_slaves = function(self)
        local sentinel = self:ctx().sentinel
        local res, err = sentinel:sentinel(
            "slaves",
            self:config_get("redis_sentinel_master_name")
        )
        if type(res) == "table" then
            local hosts = {}
            for _,slave in ipairs(res) do
                local host = {}
                for i = 1, #slave, 2 do
                    if slave[i] == "ip" then
                        host.host = slave[i + 1]
                    elseif slave[i] == "port" then
                        host.port = slave[i + 1]
                        break
                    end
                end
                if host.host and host.port then
                    tbl_insert(hosts, host)
                end
            end
            if next(hosts) ~= nil then
                self:config_set("redis_hosts", hosts)
                self:e "redis_slaves_selected"
            end
        end
        self:e "redis_selection_failed"
    end,

    sleeping = function(self)
        local last_sleep = self:ctx().last_sleep or 0
        local sleep = last_sleep + 5
        ngx_log(ngx_ERR, "sleeping for ", sleep, "s before reconnecting...")
        ngx_sleep(sleep)
        self:ctx().last_sleep = sleep
        self:e "woken"
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

    considering_esi_scan = function(self)
        if self:config_get("esi_enabled") == true then
            local res = self:get_response()
            local res_content_type = res.header["Content-Type"]

            if res_content_type then
                local allowed_types = self:config_get("esi_content_types") or {}

                for _, content_type in ipairs(allowed_types) do
                    if str_sub(res_content_type, 1, str_len(content_type)) == content_type then
                        return self:e "esi_scan_enabled"
                    end
                end
            end
        end

        return self:e "esi_scan_disabled"
    end,


    -- We decide to process if:
    --  - We know the response has_esi (fast path)
    --  - We already decided to scan for esi (slow path)
    --  - We aren't delegating responsibility downstream, which would occur if:
    --      - Delegation is blindly set to true
    --      - Delegation IP table contains the request IP
    --
    --  So essentially, if we think we may need to process, then we do. We don't want to 
    --  accidentally send ESI instructions to a client, so we only delegate if we're sure.
    considering_esi_process = function(self)
        local res = self:get_response()

        -- If res.has_esi then we're on the fast path and know there's work to be done.
        -- If res.esi_scan_enabled, then we're on the slow path, but we already checked if we
        -- should scan earlier, so can assume there *may* be work to do.
        if res.has_esi == true or self:ctx().esi_scan_enabled == true then
            -- Check s/c
            local surrogate_capability = ngx.req.get_headers()["Surrogate-Capability"]

            -- TODO: We should have a sense of capability tokens somewhere, perhaps
            -- instantiating different parsers (ESI/1.0 EdgeSuite/5.0) etc. 
            -- For now, if the surrogate claims *any* capabaility, then we blindly delegate
            -- so long as delegation is enabled or the request IP is in the table of IPs.
            if surrogate_capability then
                local surrogates = self:config_get("esi_allow_surrogate_delegation")
                if type(surrogates) == "boolean" then
                    if surrogates == true then 
                        return self:e "esi_process_disabled"
                    end
                elseif type(surrogates) == "table" then
                    local remote_addr = ngx_var.remote_addr
                    if remote_addr then
                        for _, ip in ipairs(surrogates) do
                            if ip == remote_addr then
                                return self:e "esi_process_disabled"
                            end
                        end
                    end
                end
            end
            
            return self:e "esi_process_enabled"
        end

        return self:e "esi_process_disabled"
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
        local lock_key = self:fetching_key()
        
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
            redis:unwatch()
            ngx_log(ngx_ERR, err)
            return self:e "collapsed_forwarding_failed"
        elseif res == "OK" then -- We have the lock
            redis:unwatch()
            return self:e "obtained_collapsed_forwarding_lock"
        elseif res == "BUSY" then -- Lock is busy
            redis:multi()
            redis:subscribe(self:cache_key())
            if redis:exec() ~= ngx_null then -- We subscribed before the lock was freed
                return self:e "subscribed_to_collapsed_forwarding_channel"
            else -- Lock was freed before we subscribed
                return self:e "collapsed_forwarding_channel_closed"
            end
        end
    end,

    publishing_collapse_success = function(self)
        local redis = self:ctx().redis
        redis:del(self:fetching_key()) -- Clear the lock
        redis:publish(self:cache_key(), "collapsed_response_ready")
        self:e "published"
    end,

    publishing_collapse_failure = function(self)
        local redis = self:ctx().redis
        redis:del(self:fetching_key()) -- Clear the lock
        redis:publish(self:cache_key(), "collapsed_forwarding_failed")
        self:e "published"
    end,

    publishing_collapse_upstream_error = function(self)
        local redis = self:ctx().redis
        redis:del(self:fetching_key()) -- Clear the lock
        redis:publish(self:cache_key(), "collapsed_forwarding_upstream_error")
        self:e "published"
    end,

    publishing_collapse_abort = function(self)
        local redis = self:ctx().redis
        redis:del(self:fetching_key()) -- Clear the lock
        -- Surrogate aborted, go back and attempt to fetch or collapse again
        redis:publish(self:cache_key(), "can_fetch_but_try_collapse")
        self:e "aborted"
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
            redis:set_timeout(self:config_get("redis_timeout"))
            redis:unsubscribe()

            -- Returns either "collapsed_response_ready" or "collapsed_forwarding_failed"
            return self:e(res[3]) 
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

    purging = function(self)
        if self:expire() then
            return self:e "purged"
        else
            return self:e "nothing_to_purge"
        end
    end,

    considering_stale_error = function(self)
        if self:accepts_stale_error() then
            local res = self:get_response()
            if res:stale_ttl() <= 0 then
                return self:e "serve_stale"
            else
                return self:e "response_ready"
            end
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

    revalidating_upstream = function(self)
        local res = self:get_response()

        if res.status >= 500 then
            return self:e "upstream_error"
        elseif res.status == ngx.HTTP_NOT_MODIFIED then
            return self:e "response_ready"
        else
            return self:e "response_fetched"
        end
    end,

    revalidating_in_background = function(self)
        return self:e "response_fetched"
    end,

    checking_can_serve_stale = function(self)
        if self:calculate_stale_ttl() > 0 then
            return self:e "serve_stale"
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
            ngx_log(ngx_DEBUG, "#a: ", action)
            self.actions[action](self)
        end
    end

    ngx_log(ngx_DEBUG, "#t: ", state)

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


-- Process state transitions and actions based on the event fired.
function _M.e(self, event)
    ngx_log(ngx_DEBUG, "#e: ", event)

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
                                ngx_log(ngx_DEBUG, "#a: ", action)
                                self.actions[action](self)
                            end
                        else
                            ngx_log(ngx_DEBUG, "#a: ", t_but_first)
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
    local redis = self:ctx().redis
    local res = response.new()

    local cache_key = self:cache_key()

    local entity_keys = self:cache_entity_keys(cache_key)

    if not entity_keys  then
        -- MISS
        return nil
    end

    -- Get our body reader coroutine for later
    res.body_reader = self:get_cache_body_reader(entity_keys)

    -- Read main metdata
    local cache_parts, err = redis:hgetall(entity_keys.main)
    if not cache_parts then
        ngx_log(ngx_ERR, err)
        return nil
    end

    -- No cache entry for this key
    local cache_parts_len = #cache_parts
    if not cache_parts_len then
        ngx_log(ngx_ERR, "live entity has no data")
        return nil
    end

    local ttl = nil
    local time_in_cache = 0
    local time_since_generated = 0

    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, cache_parts_len, 2 do
        if cache_parts[i] == "uri" then
            res.uri = cache_parts[i + 1]
        elseif cache_parts[i] == "status" then
            res.status = tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "expires" then
            res.remaining_ttl = tonumber(cache_parts[i + 1]) - ngx_time()
        elseif cache_parts[i] == "saved_ts" then
            time_in_cache = ngx_time() - tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "generated_ts" then
            time_since_generated = ngx_time() - tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "has_esi" then
            -- TODO: We should store this as an integer?
            local has_esi = cache_parts[i + 1]
            res.has_esi = cache_parts[i + 1] == "true"
        elseif cache_parts[i] == "size" then
            res.size = tonumber(cache_parts[i + 1])
        end
    end

    -- Read headers
    local headers = redis:hgetall(entity_keys.headers)
    if headers then
        local headers_len = tbl_getn(headers)

        for i = 1, headers_len, 2 do
            local header = headers[i]
            if str_find(header, ":") then
                -- We have multiple headers with the same field name
                local index, key = unpack(str_split(header, ":"))
                if not res.header[key] then
                    res.header[key] = {}
                end
                tbl_insert(res.header[key], headers[i + 1])
            else
                res.header[header] = headers[i + 1]
            end
        end

        -- Calculate the Age header
        if res.header["Age"] then
            -- We have end-to-end Age headers, add our time_in_cache.
            res.header["Age"] = tonumber(res.header["Age"]) + time_in_cache
        elseif res.header["Date"] then
            -- We have no advertised Age, use the generated timestamp.
            res.header["Age"] = time_since_generated
        end
    end

    -- Modify the response with request range if needed.
    local res = self:check_range_request(res)

    self:emit("cache_accessed", res)

    return res
end


function _M.check_range_request(self, res)
    local range_request = self:request_byte_range()

    if range_request and type(range_request) == "table" then
        local ranges = {}

        for i,range in ipairs(range_request) do
            local range_satisfiable = true

            if not range.to and not range.from then
                range_satisfiable = false
            end

            -- A missing "to" means to the "end".
            if not range.to then 
                if res.has_esi then
                    range_satisfiable = false
                else
                    range.to = res.size - 1 
                end
            end

            -- A missing "from" means "to" is an offset from the end.
            if not range.from then 
                range.from = res.size - (range.to)
                range.to = res.size - 1

                if range.from < 0 then
                    range_satisfiable = false
                end
            end

            -- A "to" greater than size should be "end"
            if range.to > (res.size - 1) then 
                range.to = res.size - 1 
            end

            -- Check the range is satisfiable
            if range.from > range.to or range.to > res.size then
                range_satisfiable = false
            end

            if not range_satisfiable then
                -- We'll return 416 
                res.status = ngx_RANGE_NOT_SATISFIABLE
                res.body_reader = nil
                res.header.content_range = "bytes */" .. res.size

                return res
            else
                -- We'll need the content range header value for multipart boundaries
                range.header = "bytes " .. range.from .. "-" .. range.to .. "/" .. res.size
                tbl_insert(ranges, range)
            end
        end
        
        local numranges = #ranges
        if numranges > 1 then
            -- Sort ranges as we cannot serve unordered.
            tbl_sort(ranges, sort_byte_ranges)

            -- Coalesce overlapping ranges.
            for i = numranges,1,-1 do
                if i > 1 then
                    local current_range = ranges[i]
                    local previous_range = ranges[i - 1]

                    if current_range.from <= previous_range.to then
                        -- extend previous range to encompass this one
                        previous_range.to = current_range.to
                        previous_range.header = "bytes " .. 
                                                previous_range.from .. "-" .. current_range.to 
                                                .. "/" .. res.size
                        tbl_remove(ranges, i)
                    end
                end
            end
        end

        self:ctx().byterange_request_ranges = ranges

        if #ranges == 1 then
            -- We have a single range to serve.
            local range = ranges[1]

            local size = res.size
            if res.has_esi then 
                -- If we have ESI to do then advertise an unknown length since
                -- we cannot know this in advance.
                size = "*"
            end

            res.status = ngx_PARTIAL_CONTENT
            ngx.header["Accept-Ranges"] = "bytes"
            res.header["Content-Range"] = "bytes " .. range.from .. "-" .. range.to .. "/" .. size

            return res
        else
            -- Generate boundary and store it in ctx
            local boundary_string = random_hex(32)
            local boundary = {
                "",
                "--" .. boundary_string,
            }

            if res.header["Content-Type"] then
                tbl_insert(boundary, "Content-Type: " .. res.header["Content-Type"])
                tbl_insert(boundary, "")
            end
            
            self:ctx().byterange_boundary = tbl_concat(boundary, "\n")
            self:ctx().byterange_boundary_end = "\n--" .. boundary_string .. "--"

            res.status = ngx_PARTIAL_CONTENT
            ngx.header["Accept-Ranges"] = "bytes"
            res.header["Content-Type"] = "multipart/byteranges; boundary=" .. boundary_string

            return res
        end
    end

    return res
end


-- Fetches a resource from the origin server.
function _M.fetch_from_origin(self)
    local res = response.new()
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
            end
        end
    end

    -- Filter out range requests (we always fetch everything, and serve only what is required)
    local headers = ngx_req_get_headers()

    local origin, err = httpc:request{
        method = ngx_req_get_method(),
        path = self:relative_uri(),
        body = httpc:get_client_body_reader(self:config_get("buffer_size")),
        headers = headers,
    }

    if not origin then
        ngx_log(ngx_ERR, err)
        res.status = 524
        return res
    end

    res.conn = httpc
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

    -- We always use the esi scan filter. It will simply yield if there is no work to be done.
    res.body_reader = self:get_esi_scan_filter(origin.body_reader)

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


function _M.save_to_cache(self, res)
    self:emit("before_save", res)

    local uncacheable_headers = {}

    local length = res.length
    local max_memory = (self:config_get("cache_max_memory") or 0) * 1024

    if length and length > max_memory then
        -- We'll carry on serving, just not saving.
        return nil
    end

    -- Also don't cache any headers marked as Cache-Control: (no-cache|no-store|private)="header".
    local cc = res.header["Cache-Control"]
    if cc then
        if type(cc) == "table" then cc = tbl_concat(cc, ", ") end

        if str_find(cc, "=") then
            local patterns = { "no%-cache", "no%-store", "private" }
            for _,p in ipairs(patterns) do
                for h in str_gmatch(cc, p .. "=\"?([%a-]+)\"?") do
                    tbl_insert(uncacheable_headers, h)
                end
            end
        end
    end

    -- Utility to search in uncacheable_headers.
    local function is_uncacheable(t, h)
        for _, v in ipairs(t) do
            if str_lower(v) == str_lower(h) then
                return true
            end
        end
        return nil
    end

    -- Turn the headers into a flat list of pairs for the Redis query.
    local h = {}
    for header,header_value in pairs(res.header) do
        if not is_uncacheable(uncacheable_headers, header) then
            if type(header_value) == 'table' then
                -- Multiple headers are represented as a table of values
                local header_value_len = tbl_getn(header_value)
                for i = 1, header_value_len do
                    tbl_insert(h, i..':'..header)
                    tbl_insert(h, header_value[i])
                end
            else
                tbl_insert(h, header)
                tbl_insert(h, header_value)
            end
        end
    end
    
    local ttl = res:ttl()
    local expires = ttl + ngx_time()
    local uri = self:full_uri()
    

    local redis = self:ctx().redis
    local cache_key = self:cache_key()
    
    -- Create new entity keys
    local entity = random_hex(8)  
    local entity_keys = self:entity_keys(cache_key .. ":" .. entity)
    
    -- We'll need to mark the old entity for expiration shortly, as reads could still 
    -- be in progress. We need to know the previous entity keys and the size.
    local previous_entity_keys = self:cache_entity_keys(cache_key)

    local previous_entity_size, err
    if previous_entity_keys then
        previous_entity_size, err = redis:hget(previous_entity_keys.main, "size")
        if previous_entity_size == ngx_null then
            previous_entity_keys = nil
            if err then
                ngx_log(ngx_ERR, err)
            end
        end
    end

    -- Start the transaction
    redis:multi()

    if previous_entity_keys then
        -- We use the previous entity size and the minimum download rate to calculate when to expire
        -- the old entity, plus 1 second of arbitrary latency for good measure.
        local dl_rate_Bps = self:config_get("minimum_old_entity_download_rate") * 128 -- Bytes in a kb
        local gc_after = math_ceil((previous_entity_size / dl_rate_Bps)) + 1

        local qless_db = self:config_get("redis_qless_database") or 1
        redis:select(qless_db)

        -- Place this job on the queue
        self:put_background_job("ledge", "ledge.jobs.collect_entity", {
            cache_key = cache_key,
            size = previous_entity_size,
            entity_keys = previous_entity_keys, 
        }, { delay = gc_after })
    end

    redis:hmset(entity_keys.main,
        'status', res.status,
        'uri', uri,
        'expires', expires,
        'generated_ts', ngx_parse_http_time(res.header["Date"]),
        'saved_ts', ngx_time()
    )

    redis:hmset(entity_keys.headers, unpack(h))

    -- Mark the keys as eventually volatile (the body is set by the body writer)
    local keep_cache_for = ttl + tonumber(self:config_get("keep_cache_for"))
    redis:expire(entity_keys.main, keep_cache_for)
    redis:expire(entity_keys.headers, keep_cache_for)

    -- Update main cache key pointer
    redis:set(cache_key, entity)

    -- Instantiate writer coroutine with the entity key set.
    -- The writer will commit the transaction later.
    if res.has_body then
        res.body_reader = self:get_cache_body_writer(
            res.body_reader, 
            entity_keys, 
            keep_cache_for
        )
    else
        -- Run transaction
        if redis:exec() == ngx_null then
            ngx_log(ngx_ERR, "Failed to save cache item")
        end
    end
end


function _M.delete_from_cache(self)
    local cache_key = self:cache_key()
    local entity_keys = self:cache_entity_keys(cache_key)
    if entity_keys then
        local redis = self:ctx().redis
        local keys = { cache_key, cache_key .. ":entities", cache_key .. ":memused" }
        local i = #keys
        for k,v in pairs(entity_keys) do
            i = i + 1
            keys[i] = v
        end
        return redis:del(unpack(keys))
    end
end


function _M.expire(self)
    local cache_key = self:cache_key()
    local entity_keys = self:cache_entity_keys(cache_key)
    if not entity_keys then return false end -- nothing to expire

    local redis = self:ctx().redis
    if redis:exists(entity_keys.main) == 1 then
        local ok, err = redis:hset(entity_keys.main, "expires", tostring(ngx_time() - 1))
        if not ok then
            ngx_log(ngx_ERR, err)
            return false
        else
            return true
        end
    else
        return false
    end
end


function _M.serve(self)
    if not ngx.headers_sent then
        local res = self:get_response() -- or self:get_response("fetched")
        assert(res.status, "Response has no status.") -- FIXME: This will bail hard on error.

        local visible_hostname = self:visible_hostname()

        -- Via header
        local via = "1.1 " .. visible_hostname .. " (ledge/" .. _M._VERSION .. ")"
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

        if not ctx.event_history["response_not_cacheable"] then
            local x_cache = "HIT from " .. visible_hostname
            if state_history["fetching"] or state_history["revalidating_upstream"] then
                x_cache = "MISS from " .. visible_hostname
            end

            local res_x_cache = res.header["X-Cache"]

            if res_x_cache ~= nil then
                res.header["X-Cache"] = x_cache .. ", " .. res_x_cache
            else
                res.header["X-Cache"] = x_cache
            end
        end

        -- We know the body has esi markup, so zero downstream lifetime.
        if self:config_get("esi_enabled") and res.has_esi or res.downstream_lifetme == 0 then
            res.header["Cache-Control"] = "private, must-revalidate"
        end

        self:emit("response_ready", res)

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        if res.body_reader then
            -- Go!
            self:body_server(res.body_reader)
        end

        ngx.eof()
    end
end


-- Returns a wrapped coroutine to be resumed for each body chunk.
function _M.get_cache_body_reader(self, entity_keys)
    local redis = self:ctx().redis

    local num_chunks = redis:llen(entity_keys.body) - 1
    if num_chunks < 0 then return nil end

    local has_esi = false

    return co_wrap(function()
        local process_esi = self:ctx().esi_process_enabled

        for i = 0, num_chunks do
            local chunk, err = redis:lindex(entity_keys.body, i)

            -- Just for efficiency, we avoid the lookup. The body server is responsible
            -- for deciding whether to call process_esi() or not.
            if process_esi == true then
                has_esi, err = redis:lindex(entity_keys.body_esi, i)
            end

            if chunk == ngx_null then
                ngx_log(ngx_WARN, "entity removed during read, ", entity_keys.main)
                self:e "entity_removed_during_read"
            end

            co_yield(chunk, has_esi == "true")
        end
    end)
end


-- Returns a wrapped coroutine for writing chunks to cache, where reader is a
-- coroutine to be resumed which reads from the upstream socket.
-- If we cross the max_memory boundary, we just keep yielding chunks to be served,
-- after having removed the cache entry.
function _M.get_cache_body_writer(self, reader, entity_keys, ttl)
    local redis = self:ctx().redis
    local max_memory = (self:config_get("cache_max_memory") or 0) * 1024
    local deleted_due_to_size = false
    local esi_detected = false

    return co_wrap(function(buffer_size)
        local size = 0
        repeat
            local chunk, has_esi, err = reader(buffer_size)
            if chunk then
                if not deleted_due_to_size then
                    size = size + #chunk

                    -- If we cannot store any more, delete everything.
                    -- TODO: Options for persistent storage and retaining metadata etc.
                    if size > max_memory then
                        deleted_due_to_size = true
                        local res, err = redis:discard()
                        if err then
                            ngx_log(ngx_ERR, err)
                        end
                        self:delete_from_cache()

                        ngx_log(ngx_NOTICE, "cache item deleted as it is larger than ", 
                                            max_memory, " bytes")
                    else
                        redis:rpush(entity_keys.body, chunk)
                        redis:rpush(entity_keys.body_esi, tostring(has_esi))

                        if not esi_detected and has_esi then
                            -- Flag this in the main key
                            redis:hset(entity_keys.main, "has_esi", "true")
                            esi_detected = true
                        end
                    end
                end
                co_yield(chunk, has_esi)
            end
        until not chunk

        if not deleted_due_to_size then
            redis:hset(entity_keys.main, "size", size)

            local cache_key = self:cache_key()
            redis:incrby(self:cache_key() .. ":memused", size)
            redis:zadd(self:cache_key() .. ":entities", size, entity_keys.main) 
            redis:expire(entity_keys.body, ttl)

            local res, err = redis:exec()
            if err then
                ngx_log(ngx_ERR, err)
            end
        end
    end)
end


-- Reads from reader according to "buffer_size", and scans for ESI instructions.
-- Acts as a sink when ESI instructions are not complete, buffering until the chunk
-- contains a full instruction safe to process on serve.
function _M.get_esi_scan_filter(self, reader)
    local redis = self:ctx().redis

    return co_wrap(function(buffer_size)
        local prev_chunk = ""
        local buffering = false
        local esi_enabled = self:ctx().esi_scan_enabled

        repeat
            local chunk, err = reader(buffer_size)
            if not esi_enabled then
                co_yield(chunk, false, err)
            else
                local has_esi = false

                if chunk then
                    chunk = prev_chunk .. chunk
                    local chunk_len = #chunk

                    local pos = 1

                    repeat
                        local is_comment = false

                        -- 1) Look for an opening esi tag
                        local start_from, start_to, err = ngx_re_find(
                            str_sub(chunk, pos), 
                            "<[!--]*esi", "soj"
                        )

                        if not start_from then
                            -- Nothing to do in this chunk, stop looping.
                            break
                        else
                            -- We definitely have something.
                            -- ngx_log(ngx_INFO, "adding warning")
                            has_esi = true

                            -- Give our start tag positions absolute chunk positions.
                            start_from = start_from + (pos - 1)
                            start_to = start_to + (pos - 1)

                            local end_from, end_to, err

                            -- 2) Try and find the end of the tag (could be inline or block)
                            --    and comments must be treated as special cases.
                            if str_sub(chunk, start_from, 7) == "<!--esi" then
                                end_from, end_to, err = ngx_re_find(
                                    str_sub(chunk, start_to + 1),
                                    "-->", "soj"
                                )
                            else
                                end_from, end_to, err = ngx_re_find(
                                    str_sub(chunk, start_to + 1), 
                                    "[^>]?/>|</esi:[^>]+>", "soj"
                                )
                            end

                            if not end_from then
                                -- The end isn't in this chunk, so we must buffer.
                                prev_chunk = chunk
                                buffering = true
                                break
                            else
                                -- We found the end of this instruction. Stop buffering until we find
                                -- another unclosed instruction.
                                prev_chunk = "" 
                                buffering = false

                            end_from = end_from + start_to
                        end_to = end_to + start_to 

                        -- Update pos for the next loop
                        pos = end_to + 1
                    end
                end
            until pos >= chunk_len

            if not buffering then
                -- We've got a chunk we can yield with.
                co_yield(chunk, has_esi)
            end
        end
    end
        until not chunk
    end)
end


function _M.get_esi_process_filter(self, reader)
    return co_wrap(function(buffer_size)
        local i = 1
        repeat
            local chunk, has_esi, err = reader(buffer_size)
            if chunk then
                if has_esi then
                    local replace = function(var)
                        if var == "$(QUERY_STRING)" then
                            return ngx_var.args or ""
                        elseif str_sub(var, 1, 7) == "$(HTTP_" then
                            -- Look for a HTTP_var that matches
                            local _, _, header = str_find(var, "%$%(HTTP%_(.+)%)")
                            if header then
                                return ngx_var["http_" .. header] or ""
                            else
                                return ""
                            end
                        else
                            return ""
                        end
                    end

                    -- For every esi:vars block, substitute any number of variables found.
                    chunk = ngx_re_gsub(chunk, "<esi:vars>(.*)</esi:vars>", function(var_block)
                        return ngx_re_gsub(var_block[1], "\\$\\([A-Z_]+[{a-zA-Z\\.-~_%0-9}]*\\)", 
                        function (m)
                            return replace(m[0])
                        end,
                        "soj")
                    end, "soj")

                    -- Remove vars tags that are left over
                    chunk = ngx_re_gsub(chunk, "(<esi:vars>|</esi:vars>)", "", "soj")

                    -- Replace vars inline in any other esi: tags.
                    chunk = ngx_re_gsub(chunk, "(<esi:)(.+)(.*/>)",
                    function(m)
                        local vars = ngx_re_gsub(m[2],
                        "(\\$\\([A-Z_]+[{a-zA-Z\\.-~_%0-9}]*\\))",
                        function (m)
                            return replace(m[1])
                        end,
                        "oj")
                        return m[1] .. vars .. m[3]
                    end,
                    "oj")

                    chunk = ngx_re_gsub(chunk, "(<!--esi(.*?)-->)", "$2", "soj")

                    chunk = ngx_re_gsub(chunk, "(<esi:remove>.*?</esi:remove>)", "", "soj")


                    -- Find and loop start points of includes
                    
                    local ctx = { pos = 1 }
                    local yield_from = 1
                    repeat
                        local from, to, err = ngx_re_find(
                            chunk, 
                            "<esi:include src=\".+\".*/>", 
                            "oj", 
                            ctx
                        )

                        if from then
                            -- Yield up to the start of the include tag
                            co_yield(str_sub(chunk, yield_from, from - 1))
                            yield_from = to + 1

                            local src, err = ngx_re_match(
                                str_sub(chunk, from, to), 
                                "src=\"(.+)\".*/>",
                                "oj"
                            )

                            if src then
                                local httpc = http.new()
                                
                                local scheme, host, port, path
                                local uri_parts = httpc:parse_uri(src[1])

                                if not uri_parts then
                                    -- Not a valid URI, so probably a relative path. Resolve
                                    -- local to the current request.
                                    scheme = ngx_var.scheme
                                    host = ngx_var.http_host or ngx_var.host
                                    port = ngx_var.server_port
                                    path = src[1]
                                else
                                    scheme, host, port, path = unpack(uri_parts)
                                end

                                if host == "localhost" then host = "127.0.0.1" end

                                local res, err = httpc:connect(host, port)
                                if not res then
                                    ngx_log(ngx_ERR, err)
                                    co_yield()
                                else
                                    local headers = ngx_req_get_headers()

                                    -- Remove client validators
                                    headers["if-modified-since"] = nil
                                    headers["if-none-match"] = nil

                                    headers["host"] = host
                                    headers["accept-encoding"] = nil

                                    local res, err = httpc:request{ 
                                        method = ngx_req_get_method(),
                                        path = path,
                                        headers = headers,
                                    }

                                    if res then
                                        -- Stream the include fragment, yielding as we go
                                        local reader = res.body_reader
                                        repeat
                                            local ch, err = reader(buffer_size)
                                            if ch then
                                                co_yield(ch)
                                            end
                                        until not ch
                                    end

                                    httpc:set_keepalive()
                                end
                            end
                        else
                            co_yield(str_sub(chunk, ctx.pos, #chunk))
                        end

                    until not from
                else
                    co_yield(chunk)
                end
            end

            i = i + 1
        until not chunk
    end)
end


-- Filters the body reader, only yielding bytes specified in a range request.
function _M.get_range_request_filter(self, reader)
    local ranges = self:ctx().byterange_request_ranges
    local boundary_end = self:ctx().byterange_boundary_end
    local boundary = self:ctx().byterange_boundary

    if ranges then
        return co_wrap(function(buffer_size)
            local playhead = 0
            local num_ranges = #ranges

            repeat
                local chunk, err = reader(buffer_size)
                if chunk then
                    local chunklen = #chunk
                    local nextplayhead = playhead + chunklen

                    for i, range in ipairs(ranges) do
                        if range.from >= nextplayhead or range.to < playhead then
                            -- Skip over non matching ranges (this is algoritmically simpler)
                        else
                            -- Yield the multipart byterange boundary if required
                            -- and only once per range.
                            if num_ranges > 1 and not range.boundary_printed then
                                co_yield(boundary)
                                co_yield("Content-Range: " .. range.header .. "\n\n")
                                range.boundary_printed = true
                            end

                            -- Trim range to within this chunk's context
                            local yield_from = range.from
                            local yield_to = range.to
                            if range.from < playhead then
                                yield_from = playhead
                            end
                            if range.to >= nextplayhead then
                                yield_to = nextplayhead - 1
                            end

                            -- Find relative points for the range within this chunk
                            local relative_yield_from = yield_from - playhead
                            local relative_yield_to = yield_to - playhead

                            -- Ranges are all 0 indexed, finally convert to 1 based Lua indexes.
                            co_yield(str_sub(chunk, relative_yield_from + 1, relative_yield_to + 1))
                        end
                    end

                    playhead = playhead + chunklen
                end

            until not chunk
            
            -- Yield the multipart byterange end marker
            if num_ranges > 1 then
                co_yield(boundary_end)
            end
        end)
    end

    return reader
end


-- Resumes the reader coroutine and prints the data yielded. This could be
-- via a cache read, or a save via a fetch... the interface is uniform.
function _M.body_server(self, reader)
    local buffer_size = self:config_get("buffer_size")
    local process_esi = self:ctx().esi_process_enabled
    local request_range = self:ctx().byterange_request_ranges

    -- Filter response for ESI if required
    if process_esi then
        reader = self:get_esi_process_filter(reader)
    end
    
    -- Filter response by requested range if required
    if request_range then
        reader = self:get_range_request_filter(reader)
    end

    repeat
        local chunk, err = reader(buffer_size)
        if chunk then
            ngx_print(chunk)
        end

    until not chunk
end


function _M.add_warning(self, code)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local header = code .. ' ' .. self:visible_hostname() .. ' "' .. WARNINGS[code] .. '"'
    tbl_insert(res.header["Warning"], header)
end


return _M

