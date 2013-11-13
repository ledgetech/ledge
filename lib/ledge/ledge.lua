local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_print = ngx.print
local ngx_get_phase = ngx.get_phase
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_req_get_method = ngx.req.get_method
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_re_gsub = ngx.re.gsub
local ngx_re_gmatch = ngx.re.gmatch
local ngx_var = ngx.var
local tbl_insert = table.insert
local tbl_concat = table.concat
local tbl_remove = table.remove
local tbl_getn = table.getn
local str_lower = string.lower
local co_wrap = coroutine.wrap
local co_yield = coroutine.yield


local _M = {
    _VERSION = '0.09'
}

local mt = { __index = _M }

local redis = require "resty.redis"
local http = require "resty.http"
local response = require "ledge.response"
local h_util = require "ledge.header_util"


-- Origin modes, for serving stale content during maintenance periods or emergencies.
_M.ORIGIN_MODE_BYPASS = 1 -- Never goes to the origin, serve from cache where possible or 503.
_M.ORIGIN_MODE_AVOID  = 2 -- Avoids going to the origin, serving from cache where possible.
_M.ORIGIN_MODE_NORMAL = 4 -- Assume the origin is happy, use at will.


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

        upstream_host = "",
        upstream_port = 80,

        redis_database  = 0,
        redis_timeout   = 100,          -- Connect and read timeout (ms)
        redis_keepalive_timeout = nil,  -- Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- Defaults to 30 or lua_socket_pool_size
        redis_hosts = {
            { host = "127.0.0.1", port = 6379, socket = nil, password = nil }
        },
        redis_use_sentinel = false,
        redis_sentinels = {},

        keep_cache_for  = 86400 * 30,   -- Max time to Keep cache items past expiry + stale (sec)
        max_stale       = nil,          -- Warning: Violates HTTP spec
        stale_if_error  = nil,          -- Max staleness (sec) for a cached response on upstream error
        enable_esi      = false,
        enable_collapsed_forwarding = false,
        collapsed_forwarding_window = 60 * 1000,   -- Window for collapsed requests (ms)
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


function _M.cleanup(self)
    -- Use a closure to pass through the ledge instance
    local ledge = self
    return function ()
                ledge:e "aborted"
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
    local set, msg = ngx.on_abort(self:cleanup())
    if set == nil then
        ngx_log(ngx_WARN, "on_abort handler not set: "..msg)
    end
    self:e "init"
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


-- Tries hosts in the order given, and returns a redis connection (which may not be connected).
function _M.redis_connect(self, hosts)
    local redis = redis:new()

    local timeout = self:config_get("redis_timeout")
    if timeout then
        redis:set_timeout(timeout)
    end

    local ok, err

    for _, conn in ipairs(hosts) do
        ok, err = redis:connect(conn.socket or conn.host, conn.port or 0)
        if ok then 
            -- Attempt authentication.
            local password = conn.password
            if password then
                ok, err = redis:auth(password)
            end

            -- redis:select always returns OK
            local database = self:config_get("redis_database")
            if database > 0 then
                redis:select(database)
            end

            break -- We're done
        end
    end

    return ok, err, redis
end


-- Close and optionally keepalive the redis (and sentinel if enabled) connection.
function _M.redis_close(self)
    local redis = self:ctx().redis
    local sentinel = self:ctx().sentinel
    if redis then
        self:_redis_close(redis)
    end
    if sentinel then
        self:_redis_close(sentinel)
    end
end


function _M._redis_close(self, redis)
    -- Keep the Redis connection based on keepalive settings.
    local ok, err = nil
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
        ngx_log(ngx_WARN, "couldn't set keepalive, "..err)
    end
end


function _M.accepts_stale(self, res)
    -- max_stale config overrides everything
    local max_stale = self:config_get("max_stale")
    if max_stale and max_stale > 0 then
        return max_stale
    end

    -- Check response for headers that prevent serving stale
    local res_cc = res.header["Cache-Control"]
    if h_util.header_has_directive(res_cc, 'revalidate') or
        h_util.header_has_directive(res_cc, 's-maxage') then
        return nil
    end

    -- Check for max-stale request header
    local req_cc = ngx_req_get_headers()['Cache-Control']
    return h_util.get_numeric_header_token(req_cc, 'max-stale')
end


function _M.calculate_stale_ttl(self)
    local res = self:get_response()
    local stale = self:accepts_stale(res) or 0
    local min_fresh = h_util.get_numeric_header_token(
        ngx_req_get_headers()['Cache-Control'],
        'min-fresh'
    )

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
            ngx_var.args,
        }
        tbl_insert(key_spec, 1, "cache_obj")
        tbl_insert(key_spec, 1, "ledge")
        self:ctx().cache_key = tbl_concat(key_spec, ":")
    end
    return self:ctx().cache_key
end


function _M.fetching_key(self)
    return self:cache_key() .. ":fetching"
end


function _M.accepts_stale_error(self)
    local req_cc = ngx_req_get_headers()['Cache-Control']
    local stale_age = self:config_get("stale_if_error")
    local res = self:get_response()

    if not res then
        return false
    end

    if not h_util.header_has_directive(req_cc, 'stale-if-error') and stale_age == nil then
        return false
    end

    -- stale_if_error config option overrides request header
    if stale_age == nil then
        stale_age = h_util.get_numeric_header_token(req_cc, 'stale-if-error')
    end

    return ((res.remaining_ttl + stale_age) > 0)
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
    -- Initial transition. Let's find out if we're connecting via Sentinel.
    init = {
        { begin = "considering_sentinel" },
    },

    -- We have sentinel config, so attempt connection.
    sentinel_configured = {
        { begin = "connecting_to_sentinel" },
    },

    -- We have no sentinel config, connect to redis hosts directly.
    sentinel_not_configured = {
        { begin = "connecting_to_redis" },
    },

    -- We successfully connected to sentinel, try selecting the master.
    sentinel_connected = {
        { begin = "selecting_redis_master" },
    },
    
    -- We failed connecting to sentinel(s). Bail.
    sentinel_connection_failed = {
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    -- We found a master, connect to it.
    redis_master_selected = {
        { begin = "connecting_to_redis" },
    },
    
    -- We failed to select a redis instance. If we were already trying slaves, then we have to bail.
    -- If we were selecting the master, try selecting (as yet unpromoted) slaves.
    redis_selection_failed = {
        { after = "selecting_redis_slaves", begin = "exiting", 
            but_first = "set_http_service_unavailable" },
        { after = "selecting_redis_master", begin = "selecting_redis_slaves" },
    },

    -- We managed to find a slave. It will be read-only, but maybe we'll get lucky and have a HIT.
    redis_slaves_selected = {
        { begin = "connecting_to_redis" },
    },

    -- We failed to connect to redis. If we were trying a master at the time, lets give the
    -- slaves a go. Otherwise, bail.
    redis_connection_failed = {
        { after = "selecting_redis_master", begin = "selecting_redis_slaves" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    -- We're connected! Let's get on with it then... First step, analyse the request.
    redis_connected = {
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
        { when = "revalidating_locally", begin = "preparing_response" },
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
        { when = "checking_cache", begin = "considering_revalidation" },
    },

    -- We need to fetch, and there are no settings telling us we shouldn't, but collapsed forwarding
    -- is on, so if cache is accepted and in an "expired" state (i.e. not missing), lets try
    -- to collapse. Otherwise we just start fetching.
    can_fetch_but_try_collapse = {
        { in_case = "cache_expired", begin = "requesting_collapse_lock" },
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

    -- We've fetched and got a response. We don't know about it's cacheabilty yet, but we must
    -- "update" in one form or another.
    response_fetched = {
        { begin = "updating_cache" },
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
        { begin = "preparing_response", but_first = "delete_from_cache" },
    },

    -- A missing response body means a HEAD request or a 304 Not Modified upstream response, for
    -- example. Generally we pass this on, but in case we're collapsing or background revalidating,
    -- ensure we either clean up the collapsees or exit respectively.
    response_body_missing = {
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
        { begin = "revalidating_upstream" },
    },

    -- We can validate locally, so do it. This doesn't imply it's valid, merely that we have
    -- the correct parameters to attempt validation.
    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    -- Standard non-conditional request.
    no_validator_present = {
        { begin = "preparing_response" },
    },

    -- The response has not been modified against the validators given. We'll exit 304 if we can
    -- but go via preparing_response in case of ESI work to be done.
    not_modified = {
        { when = "revalidating_locally", begin = "preparing_response" },
    },

    -- Our cache has been modified as compared to the validators. But cache is valid, so just
    -- serve it. If we've been upstream, re-compare against client validators.
    modified = {
        { when = "revalidating_locally", begin = "preparing_response" },
        { when = "revalidating_upstream", begin = "considering_local_revalidation" },
    },

    -- We've found ESI instructions in the response body (on the last save). Serve, but do
    -- any ESI processing first. If we got here we wont 304 to the client.
    esi_detected = {
        { begin = "serving", but_first = "process_esi" },
    },

    -- We have a response we can use. If we've already served (we are doing background work) then 
    -- just exit. If it has been prepared and we were not_modified, then set 304 and serve.
    -- If it has been prepared, set status accordingly and serve. If not, prepare it.
    response_ready = {
        { in_case = "served", begin = "exiting" },
        { in_case = "forced_cache", begin = "serving", but_first = "add_disconnected_warning"},
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
        { when = "checking_can_serve_stale", begin = "serving_stale",
            but_first = "add_stale_warning" },
        { when = "considering_stale_error", begin = "serving_stale",
            but_first = "add_stale_warning" },
    },

    -- We have sent the response. If it was stale, we go back around the fetching path
    -- so that a background revalidation can occur unless the upstream errored. Otherwise exit.
    served = {
        { in_case = "upstream_error", begin = "exiting" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "exiting" },
        { when = "serving_stale", begin = "checking_can_fetch" },
        { begin = "exiting" },
    },

    -- When the client request is aborted clean up redis connections and collapsed locks
    -- Then return ngx.exit(499) to abort any running sub-requests
    aborted = {
        { after = "publishing_collapse_abort", begin = "exiting",
             but_first = "set_http_client_abort"
        },
        { in_case = "obtained_collapsed_forwarding_lock", begin = "publishing_collapse_abort" },
        { begin = "exiting", but_first = "set_http_client_abort" },
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
    exiting = { "redis_close" },
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

    add_disconnected_warning = function(self)
        return self:add_warning("112")
    end,    

    serve = function(self)
        return self:serve()
    end,

    background_revalidate = function(self)
        local res = self:fetch_from_origin()
        if res.status ~= ngx.HTTP_NOT_MODIFIED then
            self:set_response(res)
        end
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

    process_esi = function(self)
        return self:process_esi()
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
    considering_sentinel = function(self)
        if self:config_get("redis_use_sentinel") then
            return self:e "sentinel_configured"
        else
            return self:e "sentinel_not_configured"
        end
    end,

    connecting_to_sentinel = function(self)
        local hosts = self:config_get("redis_sentinels")
        local ok, err, sentinel = self:redis_connect(hosts)
        if not ok then
            return self:e "sentinel_connection_failed"
        else
            sentinel:add_commands("sentinel")
            self:ctx().sentinel = sentinel
            return self:e "sentinel_connected"
        end
    end,

    connecting_to_redis = function(self)
        local hosts = self:config_get("redis_hosts")
        local ok, err, redis = self:redis_connect(hosts)
        if not ok then
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
         if res ~= ngx.null and res[1] and res[2] then
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
            if redis:exec() ~= ngx.null then -- We subscribed before the lock was freed
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
        if ngx_req_get_method() ~= "HEAD" then
            local res = self:get_response()
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
        if self:config_get("enable_esi") == true then
            local res = self:get_response()
            if res:has_esi() then
                return self:e "esi_detected"
            end
        end

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
}


-- Transition to a new state.
function _M.t(self, state)
    local ctx = self:ctx()

    -- Check for any transition pre-tasks
    local pre_t = self.pre_transitions[state]

    if pre_t then
        for _,action in ipairs(pre_t) do
            ngx_log(ngx_DEBUG, "#a: " .. action)
            self.actions[action](self)
        end
    end

    ngx_log(ngx_DEBUG, "#t: " .. state)

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


-- Process state transitions and actions based on the event fired.
function _M.e(self, event)
    ngx_log(ngx_DEBUG, "#e: " .. event)

    local ctx = self:ctx()
    ctx.event_history[event] = true

    -- It's possible for states to call undefined events at run time. Try to handle this nicely.
    if not self.events[event] then
        ngx_log(ngx.CRIT, event .. " is not defined.")
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
                        ngx_log(ngx_DEBUG, "#a: " .. t_but_first)
                        self.actions[t_but_first](self)
                    end

                    return self:t(trans["begin"])
                end
            end
        end
    end
end


function _M.read_from_cache(self)
    local res = response:new()
    res.body = self:read_chunk_from_cache()
    res.from_cache = true

    -- Fetch from Redis
    local cache_parts, err = self:ctx().redis:hgetall(self:cache_key())
    if not cache_parts then
        ngx_log(ngx_ERR, "Failed to read cache item: " .. err)
        return nil
    end

    -- No cache entry for this key
    if #cache_parts == 0 then
        return nil
    end

    local ttl = nil
    local time_in_cache = 0
    local time_since_generated = 0

    -- nil values here indicate esi is unknown, so prime them to false
    res.esi.has_esi_comment = false
    res.esi.has_esi_include = false
    res.esi.has_esi_vars = false
    res.esi.has_esi_remove = false

    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        -- Look for the "known" fields
        --if cache_parts[i] == "body" then
          --  res.body = cache_parts[i + 1]
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
        elseif cache_parts[i] == "esi_comment" then
            res.esi.has_esi_comment = true
        elseif cache_parts[i] == "esi_remove" then
            res.esi.has_esi_remove = true
        elseif cache_parts[i] == "esi_include" then
            res.esi.has_esi_include = true
        elseif cache_parts[i] == "esi_vars" then
            res.esi.has_esi_vars = true
        else
            -- Unknown fields will be headers, starting with "h:" prefix.
            local header = cache_parts[i]:sub(3)
            if header then
                if header:sub(2,2) == ':' then
                    -- Multiple headers, we also need to preserve the order?
                    local index = tonumber(header:sub(1,1))
                    header = header:sub(3)
                    if res.header[header] == nil then
                        res.header[header] = {}
                    end
                    res.header[header][index]= cache_parts[i + 1]
                else
                    res.header[header] = cache_parts[i + 1]
                end
            end
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

    self:emit("cache_accessed", res)

    return res
end


-- Fetches a resource from the origin server.
function _M.fetch_from_origin(self)
    local res = response:new()
    self:emit("origin_required")

    local method = ngx['HTTP_' .. ngx_req_get_method()]
    -- Unrecognised request method, do not proxy
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    ngx.req.read_body() -- Must read body into lua when passing options into location.capture

    local httpc = http.new()
    httpc:connect(self:config_get("upstream_host"), self:config_get("upstream_port"))
    
    local origin, err = httpc:request{
        method = ngx_req_get_method(),
        path = self:relative_uri(),
        body = ngx.req.get_body_data(), -- TODO: stream this into httpc?
        headers = ngx_req_get_headers(),
    }

    httpc:set_keepalive()

    if not origin then
        ngx_log(ngx_ERR, err)
        return res
    end
    
    res.status = origin.status

    -- Merge end-to-end headers
    for k,v in pairs(origin.headers) do
        if not HOP_BY_HOP_HEADERS[str_lower(k)] then
            res.header[k] = v
        end
    end

    --res.body = origin:read_body() or ""
    res.body = origin.body_reader

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

    -- Also don't cache any headers marked as Cache-Control: (no-cache|no-store|private)="header".
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("=") then
        local patterns = { "no%-cache", "no%-store", "private" }
        for _,p in ipairs(patterns) do
            for h in res.header["Cache-Control"]:gmatch(p .. "=\"?([%a-]+)\"?") do
                tbl_insert(uncacheable_headers, h)
            end
        end
    end

    -- Utility to search in uncacheable_headers.
    local function is_uncacheable(t, h)
        for _, v in ipairs(t) do
            if v:lower() == h:lower() then
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
                for i = 1, #header_value do
                    tbl_insert(h, 'h:'..i..':'..header)
                    tbl_insert(h, header_value[i])
                end
            else
                tbl_insert(h, 'h:'..header)
                tbl_insert(h, header_value)
            end
        end
    end

    local redis = self:ctx().redis

    -- Save atomically
    redis:multi()

    -- Delete any existing data, to avoid accidental hash merges.
    redis:del(self:cache_key())

    local ttl = res:ttl()
    local expires = ttl + ngx_time()
    local uri = self:full_uri()

    redis:hmset(self:cache_key(),
        'status', res.status,
        'uri', uri,
        'expires', expires,
        'generated_ts', ngx_parse_http_time(res.header["Date"]),
        'saved_ts', ngx_time(),
        unpack(h)
    )

    -- If ESI is enabled, store detected ESI features on the slow path.
    if self:config_get("enable_esi") == true then
        if res:has_esi_comment() then redis:hmset(self:cache_key(), "esi_comment", 1) end
        if res:has_esi_remove() then redis:hmset(self:cache_key(), "esi_remove", 1) end
        if res:has_esi_include() then redis:hmset(self:cache_key(), "esi_include", 1) end
        if res:has_esi_vars() then redis:hmset(self:cache_key(), "esi_vars", 1) end
    end

    redis:expire(self:cache_key(), ttl + tonumber(self:config_get("keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, uri)

    -- Run transaction
    if redis:exec() == ngx.null then
        ngx_log(ngx_ERR, "Failed to save cache item")
    end
end


function _M.delete_from_cache(self)
    return self:ctx().redis:del(self:cache_key())
end


function _M.expire(self)
    local cache_key = self:cache_key()
    local redis = self:ctx().redis
    if redis:exists(cache_key) == 1 then
        redis:hset(cache_key, "expires", tostring(ngx_time() - 1))
        return true
    else
        return false
    end
end


function _M.serve(self)
    if not ngx.headers_sent then
        local res = self:get_response() -- or self:get_response("fetched")
        assert(res.status, "Response has no status.")

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

        self:emit("response_ready", res)

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        if res.status ~= 304 then
            if res.from_cache then
                self:serve_chunk(res.body)
            else
                self:serve_chunk(self:save_chunk(res.body))
            end

--            ngx_print(res.body)
        end

        ngx.eof()
    end
end


function _M.add_warning(self, code)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local header = code .. ' ' .. self:visible_hostname() .. ' "' .. WARNINGS[code] .. '"'
    tbl_insert(res.header["Warning"], header)
end


function _M.process_esi(self)
    local res = self:get_response()
    local body = res.body

    -- Only perform transformations if we know there's work to do. This is determined
    -- during fetch (slow path).

    if res:has_esi_vars() then
        -- Function to replace vars with runtime values
        -- TODO: Possibly handle the dictionary / list syntax rather than just strings?
        -- For now we just return string presentations of the obvious things, until a
        -- need is determined.
        local replace = function(var)
            if var == "$(QUERY_STRING)" then
                return ngx_var.args or ""
            elseif var:sub(1, 7) == "$(HTTP_" then
                -- Look for a HTTP_var that matches
                local _, _, header = var:find("%$%(HTTP%_(.+)%)")
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
        body = ngx_re_gsub(body, "<esi:vars>(.*)</esi:vars>", function(var_block)
            return ngx_re_gsub(var_block[1],
                "\\$\\([A-Z_]+[{a-zA-Z\\.-~_%0-9}]*\\)",
                function(m)
                    return replace(m[0])
                end,
                "soj")
        end, "soj")

        -- Remove vars tags that are left over
        body = ngx_re_gsub(body, "(<esi:vars>|</esi:vars>)", "", "soj")

        -- Replace vars inline in any other esi: tags.
        body = ngx_re_gsub(body,
            "(<esi:)(.+)(.*/>)",
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
    end

    if res:has_esi_comment() then
        body = ngx_re_gsub(body, "(<!--esi(.*?)-->)", "$2", "soj")
    end

    if res:has_esi_remove() then
        body = ngx_re_gsub(body, "(<esi:remove>.*?</esi:remove>)", "", "soj")
    end

    if res:has_esi_include() then
        local esi_uris = {}
        for tag in ngx_re_gmatch(body, "<esi:include src=\"(.+)\".*/>", "oj") do
            tbl_insert(esi_uris, { tag[1] })
        end

        if tbl_getn(esi_uris) > 0 then
            -- Only works for relative URIs right now
            -- TODO: Extract hostname from absolute uris, and set the Host header accordingly.
            --
            
            self.actions["remove_client_validators"](self)
            local esi_fragments = { ngx.location.capture_multi(esi_uris) }
            self.actions["restore_client_validators"](self)

            -- Create response objects.
            for i,fragment in ipairs(esi_fragments) do
                esi_fragments[i] = response:new(fragment)
            end

            -- Ensure that our cacheability is reduced shortest / newest from
            -- all fragments.
            res:minimise_lifetime(esi_fragments)

            body = ngx_re_gsub(body, "(<esi:include.*/>)", function(tag)
                return tbl_remove(esi_fragments, 1).body
            end, "ioj")
        end
    end

    if res.header["Content-Length"] then res.header["Content-Length"] = #body end
    res.body = body
    self:set_response(res)
    self:add_warning("214")
end


function _M.read_chunk_from_cache(self)
    local redis = self:ctx().redis
    local cache_key = self:cache_key() .. ":body"
    local num_chunks = redis:llen(cache_key) - 1

    return co_wrap(function()
        for i = 0, num_chunks do
            local chunk, err = redis:lindex(cache_key, i)
            if not chunk then
                co_yield(nil, err)
            end

            co_yield(chunk)
        end
    end)
end


function _M.save_chunk(self, reader)
    local redis = self:ctx().redis
    local cache_key = self:cache_key() .. ":body"

    redis:multi()
    redis:del(cache_key)

    return co_wrap(function()
        repeat
            local chunk, err = reader(8192)
            if chunk then
                redis:rpush(cache_key, chunk)
                co_yield(chunk)
            end
        until not chunk
    
        local ok, err = redis:exec() == ngx.null
        if ok == ngx.null then
            ngx_log(ngx_ERR, err)
        end
    end)
end


function _M.serve_chunk(self, reader)
    repeat
        local chunk, err = reader()
        if chunk then
            ngx_print(chunk)
        end

    until not chunk
end


return _M
