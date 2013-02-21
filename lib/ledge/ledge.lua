local setmetatable = setmetatable
local error = error
local assert = assert
local require = require
local ipairs = ipairs
local pairs = pairs
local unpack = unpack
local tostring = tostring
local tonumber = tonumber
local type = type
local table = table
local ngx = ngx

module(...)

_VERSION = '0.06'

local mt = { __index = _M }

local redis = require "resty.redis"
local response = require "ledge.response"
local h_util = require "ledge.header_util"


-- Origin modes, for serving stale content during maintenance periods or emergencies.
ORIGIN_MODE_BYPASS = 1 -- Never goes to the origin, serve from cache where possible or 503.
ORIGIN_MODE_AVOID  = 2 -- Avoids going to the origin, serving from cache where possible.
ORIGIN_MODE_NORMAL = 4 -- Assume the origin is happy, use at will.


function new(self)
    local config = {
        origin_location = "/__ledge_origin",
        redis_host      = "127.0.0.1",
        redis_port      = 6379,
        redis_socket    = nil,
        redis_password  = nil,
        redis_database  = 0,
        redis_timeout   = 100,          -- Connect and read timeout (ms)
        redis_keepalive_timeout = nil,  -- Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- Defaults to 30 or lua_socket_pool_size
        keep_cache_for  = 86400 * 30,   -- Max time to Keep cache items past expiry + stale (sec)
        origin_mode     = ORIGIN_MODE_NORMAL,
        max_stale       = nil,          -- Warning: Violates HTTP spec
        enable_esi      = false,
        enable_collapsed_forwarding = false,
        collapsed_forwarding_window = 60 * 1000,   -- Window for collapsed requests (ms)
    }

    return setmetatable({ config = config }, mt)
end


-- A safe place in ngx.ctx for the current module instance (self).
function ctx(self)
    local id = tostring(self)
    local ctx = ngx.ctx[id]
    if not ctx then
        ctx = {
            events = {},
            config = {},
            state_history = {},
            event_history = {},
            current_state = "",
        }
        ngx.ctx[id] = ctx
    end
    return ctx
end


function relative_uri()
    return ngx.var.uri .. ngx.var.is_args .. (ngx.var.query_string or "")
end


function full_uri()
    return ngx.var.scheme .. '://' .. ngx.var.host .. relative_uri()
end


function visible_hostname()
    local name = ngx.var.visible_hostname or ngx.var.hostname
    if ngx.var.server_port ~= "80" and ngx.var.server_port ~= "443" then
        name = name .. ":" .. ngx.var.server_port
    end
    return name
end


function redis_connect(self)
    -- Connect to Redis. The connection is kept alive later.
    self:ctx().redis = redis:new()
    if self:config_get("redis_timeout") then
        self:ctx().redis:set_timeout(self:config_get("redis_timeout"))
    end

    local ok, err = self:ctx().redis:connect(
        self:config_get("redis_socket") or self:config_get("redis_host"),
        self:config_get("redis_port")
    )

    if ok then
        -- Attempt authentication.
        local password = self:config_get("redis_password")
        if password then
            ok, err = self:ctx().redis:auth(password)
        end
    end

    -- If we couldn't connect or authenticate, redirect to the origin directly.
    -- This means if Redis goes down, the site stands a chance of still being up.
    -- TODO: Make this configurable for situations where a 500 is better.
    if not ok then
        ngx.log(ngx.WARN, err .. ", internally redirecting to the origin")
        return ngx.exec(self:config_get("origin_location")..relative_uri())
    end

    -- redis:select always returns OK
    if self:config_get("redis_database") > 0 then
        self:ctx().redis:select(self:config_get("redis_database"))
    end
end


function redis_close(self)
    -- Keep the Redis connection based on keepalive settings.
    local ok, err = nil
    if self:config_get("redis_keepalive_timeout") then
        if self:config_get("redis_keepalive_pool_size") then
            ok, err = self:ctx().redis:set_keepalive(
                self:config_get("redis_keepalive_timeout"),
                self:config_get("redis_keepalive_pool_size")
            )
        else
            ok, err = self:ctx().redis:set_keepalive(self:config_get("redis_keepalive_timeout"))
        end
    else
        ok, err = self:ctx().redis:set_keepalive()
    end

    if not ok then
        ngx.log(ngx.WARN, "couldn't set keepalive, "..err)
    end
end


function accepts_stale(self, res)
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
    local req_cc = ngx.req.get_headers()['Cache-Control']
    return h_util.get_numeric_header_token(req_cc, 'max-stale')
end


function calculate_stale_ttl(self)
    local res = self:get_response()
    local stale = self:accepts_stale(res) or 0
    local min_fresh = h_util.get_numeric_header_token(
        ngx.req.get_headers()['Cache-Control'],
        'min-fresh'
    )

    return (res.remaining_ttl - min_fresh) + stale
end


function request_accepts_cache(self)
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        return false
    end

    -- Ignore the client requirements if we're not in "NORMAL" mode.
    if self:config_get("origin_mode") < ORIGIN_MODE_NORMAL then
        return true
    end

    -- Check for no-cache
    local h = ngx.req.get_headers()
    if h["Cache-Control"] == "no-cache" or h["Pragma"] == "no-cache" then
        return false
    end

    return true
end


function must_revalidate(self)
    local cc = ngx.req.get_headers()["Cache-Control"]
    if cc == "max-age=0" then
        return true
    else
        local res = self:get_response()
        if h_util.header_has_directive(res.header["Cache-Control"], "revalidate") then
            return true
        elseif type(cc) == "string" and res.header["Age"] then
            local max_age = cc:match("max%-age=(%d+)")
            if max_age and res.header["Age"] > tonumber(max_age) then
                return true
            end
        end
    end
    return false
end


function can_revalidate_locally(self)
    local req_h = ngx.req.get_headers()
    if  req_h["If-Modified-Since"] or req_h["If-None-Match"] then
        return true
    else
        return false
    end
end


function is_valid_locally(self)
    local req_h = ngx.req.get_headers()
    local res = self:get_response()

    if res.header["Last-Modified"] and req_h["If-Modified-Since"] then
        -- If Last-Modified is newer than If-Modified-Since.
        if ngx.parse_http_time(res.header["Last-Modified"])
            > ngx.parse_http_time(req_h["If-Modified-Since"]) then
            return false
        end
    end

    if res.header["Etag"] and req_h["If-None-Match"] then
        if res.header["Etag"] ~= req_h["If-None-Match"] then
            return false
        end
    end

    return true
end


function set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end


function get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


function cache_key(self)
    if not self:ctx().cache_key then
        -- Generate the cache key. The default spec is:
        -- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
        local key_spec = self:config_get("cache_key_spec") or {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
            ngx.var.args,
        }
        table.insert(key_spec, 1, "cache_obj")
        table.insert(key_spec, 1, "ledge")
        self:ctx().cache_key = table.concat(key_spec, ":")
    end
    return self:ctx().cache_key
end


function fetching_key(self)
    return self:cache_key() .. ":fetching"
end


-- Set a config parameter
function config_set(self, param, value)
    if ngx.get_phase() == "init" then
        self.config[param] = value
    else
        self:ctx().config[param] = value
    end
end


-- Gets a config parameter.
function config_get(self, param)
    local p = self:ctx().config[param]
    if p == nil then
        return self.config[param]
    else
        return p
    end
end


function bind(self, event, callback)
    local events = self:ctx().events
    if not events[event] then events[event] = {} end
    table.insert(events[event], callback)
end


function emit(self, event, res)
    local events = self:ctx().events
    for _, handler in ipairs(events[event] or {}) do
        if type(handler) == "function" then
            handler(res)
        end
    end
end


function run(self)
    self:e "init"
end


---------------------------------------------------------------------------------------------------
-- Event transition table.
---------------------------------------------------------------------------------------------------
-- Use "begin" to transition based on an event. Filter transitions by current state "when", and/or 
-- any previous state "after", and/or a previously fired event "in_case", and run actions using 
-- "but_first". Transitions are processed in the order found, so place more specific entries for a 
-- given event before more generic ones.
---------------------------------------------------------------------------------------------------
events = {
    -- Initial transition, always connect to redis then start checking the request.
    init = {
        { begin = "checking_request", but_first = "redis_connect" }
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
        { when = "revalidating_locally", begin = "preparing_response" }
        { begin = "checking_cache" },
    },

    -- This request doesn't accept cache, so we need to see about fetching directly.
    cache_not_accepted = {
        { begin = "checking_can_fetch" }
    },

    -- We don't know anything about this URI, so we've got to see about fetching. Since we have
    -- nothing to validate against, remove the client validators so that we don't get a conditional
    -- response upstream.
    cache_missing = {
        { begin = "checking_can_fetch", but_first = "remove_client_validators" }
    },

    -- This URI was cacheable last time, but has expired. So see about serving stale, but failing
    -- that, see about fetching and don't forget to remove client validators as per "cache_missing".
    cache_expired = {
        { when = "checking_cache", begin = "checking_can_serve_stale" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch", 
            but_first = "remove_client_validators" }
    },

    -- We have a (not expired) cache entry. Lets try and validate in case we can exit 304.
    cache_valid = {
        { when = "checking_cache", begin = "considering_revalidation" }
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

    -- We need to fetch and nothing is telling us we shouldn't. Collapsed forwarding is not enabled.
    can_fetch = {
        { begin = "fetching" }
    },

    -- We've fetched and got a response. We don't know about it's cacheabilty yet, but we must
    -- "update" in one form or another.
    response_fetched = {
        { begin = "updating_cache" }
    },

    -- We deduced that the new response can cached. We always "save_to_cache". If we were fetching
    -- as a surrogate (collapsing) make sure we tell any others concerned. If we were performing
    -- a background revalidate (having served stale), we can just exit. Otherwise see about serving.
    response_cacheable = {
        { after = "fetching_as_surrogate", begin = "publishing_collapse_success", 
            but_first = "save_to_cache" },
        { after = "revalidating_in_background", begin = "exiting", but_first = "save_to_cache" },
        { begin = "preparing_response", but_first = "save_to_cache" },
    },

    -- We've deduced that the new response cannot be cached. Essentially this is as per
    -- "response_cacheable", except we "delete" rather than "save".
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
    -- this fact, so carry on.
    published = {
        { begin = "preparing_response" }
    },

    -- We've got some validators (If-Modified-Since etc). First try local revalidation (i.e. against
    -- our own cache. If we've done that and still must_revalidate, then revalidate upstream by
    -- using validators created from our cache data (Last-Modified etc).
    must_revalidate = {
        { when = "considering_revalidation", begin = "considering_local_revalidation" },
        { when = "considering_local_revalidation", begin = "revalidating_upstream",
            but_first = "add_validators_from_cache" },
    },

    -- We can validate locally, so do it. This doesn't imply it's valid, merely that we have
    -- the correct parameters to attempt validation.
    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    -- The response has not been modified against the validators given. Exit 304 Not Modified.
    not_modified = {
        { when = "revalidating_locally", begin = "exiting", but_first = "set_http_not_modified" },
        { when = "re_revalidating_locally", begin = "exiting", but_first = "set_http_not_modified" },
        --{ when = "revalidating_upstream", begin = "re_revalidating_locally" },
        -- TODO: Add in re-revalidation. Current tests aren't expecting this.
    },

    -- The validated response has changed. If we've found this out 
    modified = {
        { when = "revalidating_locally", begin = "revalidating_upstream", 
            but_first = "add_validators_from_cache" },
        { when = "re_revalidating_locally", begin = "preparing_response" },
    },

    -- We've found ESI instructions in the response body (on the last save). Serve, but do
    -- any ESI processing first.
    esi_detected = {
        { begin = "serving", but_first = "process_esi" }
    },

    -- We have a response we can use. If it has been prepared, serve. If not, prepare it.
    response_ready = {
        { when = "preparing_response", begin = "serving" },
        { begin = "preparing_response" },
    },

    -- We've deduced we can serve a stale version of this URI. Ensure we add a warning to the
    -- response headers.
    -- TODO: "serve_stale" isn't really an event?
    serve_stale = {
        { when = "checking_can_serve_stale", begin = "serving_stale",
            but_first = "add_stale_warning" }
    },

    -- We have sent the response. If it was stale, we go back around the fetching path
    -- so that a background revalidation can occur. Otherwise exit.
    served = {
        { when = "serving_stale", begin = "checking_can_fetch" },
        { begin = "exiting" },
    },


    -- Useful events for exiting with a common status.

    http_ok = {
        { begin = "exiting", but_first = "set_http_ok" }
    },

    http_not_found = {
        { begin = "exiting", but_first = "set_http_not_found" }
    },

    http_gateway_timeout = {
        { begin = "exiting", but_first = "set_http_gateway_timeout" }
    },

    http_service_unavailable = {
        { begin = "exiting", but_first = "set_http_service_unavailable" }
    },

}


---------------------------------------------------------------------------------------------------
-- Pre-transitions. Actions to always perform before transitioning.
---------------------------------------------------------------------------------------------------
-- TODO: Perhaps actions need to be listed in an order? We can only have one right now.
pre_transitions = {
    exiting = { action = "redis_close" },
    fetching = { action = "fetch" },
    revalidating_upstream = { action = "fetch" },
    checking_cache = { action = "read_cache" },
}


---------------------------------------------------------------------------------------------------
-- Actions. Functions which can be called on transition.
---------------------------------------------------------------------------------------------------
actions = {
    redis_connect = function(self)
        return self:redis_connect()
    end,

    redis_close = function(self)
        return self:redis_close()
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
        ngx.req.set_header("If-Modified-Since", nil)
        ngx.req.set_header("If-None-Match", nil)
    end,

    add_validators_from_cache = function(self)
        local cached_res = self:get_response()

        -- TODO: Patch OpenResty to accept additional headers for subrequests.
        ngx.req.set_header("If-Modified-Since", cached_res.header["Last-Modified"])
        ngx.req.set_header("If-None-Match", cached_res.header["Etag"])
    end,

    add_stale_warning = function(self)
        return self:add_warning("110")
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
}


---------------------------------------------------------------------------------------------------
-- Decision states.
---------------------------------------------------------------------------------------------------
-- Represented as functions which should simply make a decision, and return calling self:e(ev) with 
-- the event that has occurred. Place any further logic in actions triggered by the transition 
-- table.
---------------------------------------------------------------------------------------------------
states = {
    checking_request = function(self)
        if ngx.req.get_method() == "PURGE" then
            return self:e "purge_requested"
        end

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
        if self:config_get("origin_mode") == ORIGIN_MODE_BYPASS then
            return self:e "http_service_unavailable"
        end

        if h_util.header_has_directive(
            ngx.req.get_headers()["Cache-Control"], "only-if-cached"
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
            ngx.log(ngx.ERR, "collapsed_forwarding_window must be a number")
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
                return redis.call("SETEX", KEYS[1], ARGV[1], "locked")
            else
                return "BUSY"
            end
        ]]

        local res, err = redis:eval(SETNEX, 1, lock_key, timeout)

        if not res then -- Lua script failed
            redis:unwatch()
            ngx.log(ngx.ERR, err)
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

        if res.status == ngx.HTTP_NOT_MODIFIED then
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

    considering_revalidation = function(self)
        if self:must_revalidate() then
            return self:e "must_revalidate"
        else
            -- Is this right?
            return self:e "response_ready"
        end
    end,

    considering_local_revalidation = function(self)
        if self:can_revalidate_locally() then
            return self:e "can_revalidate_locally"
        else
            return self:e "must_revalidate"
        end
    end,

    revalidating_locally = function(self)
        if self:is_valid_locally() then
            return self:e "not_modified"
        else
            return self:e "modified"
        end
    end,

    re_revalidating_locally = function(self)
        -- How do we compare against the new response?
        if self:is_valid_locally() then
            return self:e "not_modified"
        else
            return self:e "modified"
        end
    end,
    
    revalidating_upstream = function(self)
        local res = self:get_response()

        if res.status == ngx.HTTP_NOT_MODIFIED then
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
        if ngx.req.get_method() ~= "HEAD" then
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
function t(self, state)
    local ctx = self:ctx()

    -- Check for any transition pre-tasks
    local pre_t = self.pre_transitions[state]
    if pre_t and (pre_t["from"] == nil or ctx.current_state == pre_t["from"]) then
        ngx.log(ngx.DEBUG, "#a: " .. pre_t["action"])
        self.actions[pre_t["action"]](self)
    end

    ngx.log(ngx.DEBUG, "#t: " .. state)

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


-- Process state transitions and actions based on the event fired.
function e(self, event)
    ngx.log(ngx.DEBUG, "#e: " .. event)

    local ctx = self:ctx()
    ctx.event_history[event] = true

    -- It's possible for states to call undefined events at run time. Try to handle this nicely.
    if not self.events[event] then
        ngx.log(ngx.CRIT, event .. " is not defined.")
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        self:t("exiting")
    end
    
    for _, trans in ipairs(self.events[event]) do
        if trans["when"] == nil or trans["when"] == ctx.current_state then
            if not trans["after"] or ctx.state_history[trans["after"]] then 
                if not trans["in_case"] or ctx.event_history[trans["in_case"]] then
                    if trans["but_first"] then
                        ngx.log(ngx.DEBUG, "#a: " .. trans["but_first"])
                        self.actions[trans["but_first"]](self)
                    end

                    return self:t(trans["begin"])
                end
            end
        end
    end
end


function read_from_cache(self)
    local res = response:new()

    -- Fetch from Redis
    local cache_parts, err = self:ctx().redis:hgetall(cache_key(self))
    if not cache_parts then
        ngx.log(ngx.ERR, "Failed to read cache item: " .. err)
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
        if cache_parts[i] == "body" then
            res.body = cache_parts[i + 1]
        elseif cache_parts[i] == "uri" then
            res.uri = cache_parts[i + 1]
        elseif cache_parts[i] == "status" then
            res.status = tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "expires" then
            res.remaining_ttl = tonumber(cache_parts[i + 1]) - ngx.time()
        elseif cache_parts[i] == "saved_ts" then
            time_in_cache = ngx.time() - tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "generated_ts" then
            time_since_generated = ngx.time() - tonumber(cache_parts[i + 1])
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
function fetch_from_origin(self)
    local res = response:new()
    self:emit("origin_required")

    local method = ngx['HTTP_' .. ngx.req.get_method()]
    -- Unrecognised request method, do not proxy
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    local origin = ngx.location.capture(self:config_get("origin_location")..relative_uri(), {
        method = method
    })

    res.status = origin.status
    -- Merge headers in rather than wipe out the res.headers table)
    for k,v in pairs(origin.header) do
        res.header[k] = v
    end
    res.body = origin.body

    if res.status < 500 then
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx.parse_http_time(res.header["Date"]) then
            ngx.log(ngx.WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx.http_time(ngx.time())
        end
    end

    -- A nice opportunity for post-fetch / pre-save work.
    self:emit("origin_fetched", res)

    return res
end


function save_to_cache(self, res)
    self:emit("before_save", res)

    -- These "hop-by-hop" response headers MUST NOT be cached:
    -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
    local uncacheable_headers = {
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailers",
        "Transfer-Encoding",
        "Upgrade",

        -- We also choose not to cache the content length, it is set by Nginx
        -- based on the response body.
        "Content-Length",
    }

    -- Also don't cache any headers marked as Cache-Control: (no-cache|no-store|private)="header".
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("=") then
        local patterns = { "no%-cache", "no%-store", "private" }
        for _,p in ipairs(patterns) do
            for h in res.header["Cache-Control"]:gmatch(p .. "=\"?([%a-]+)\"?") do
                table.insert(uncacheable_headers, h)
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
                    table.insert(h, 'h:'..i..':'..header)
                    table.insert(h, header_value[i])
                end
            else
                table.insert(h, 'h:'..header)
                table.insert(h, header_value)
            end
        end
    end

    local redis = self:ctx().redis

    -- Save atomically
    redis:multi()

    -- Delete any existing data, to avoid accidental hash merges.
    redis:del(cache_key(self))

    local ttl = res:ttl()
    local expires = ttl + ngx.time()
    local uri = full_uri()

    redis:hmset(cache_key(self),
        'body', res.body,
        'status', res.status,
        'uri', uri,
        'expires', expires,
        'generated_ts', ngx.parse_http_time(res.header["Date"]),
        'saved_ts', ngx.time(),
        unpack(h)
    )

    -- If ESI is enabled, store detected ESI features on the slow path.
    if self:config_get("enable_esi") == true then
        if res:has_esi_comment() then redis:hmset(cache_key(self), "esi_comment", 1) end
        if res:has_esi_remove() then redis:hmset(cache_key(self), "esi_remove", 1) end
        if res:has_esi_include() then redis:hmset(cache_key(self), "esi_include", 1) end
        if res:has_esi_vars() then redis:hmset(cache_key(self), "esi_vars", 1) end
    end

    redis:expire(cache_key(self), ttl + tonumber(self:config_get("keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, uri)

    -- Run transaction
    if redis:exec() == ngx.null then
        ngx.log(ngx.ERR, "Failed to save cache item")
    end
end


function delete_from_cache(self)
    return self:ctx().redis:del(self:cache_key())
end


function expire(self)
    local cache_key = self:cache_key()
    local redis = self:ctx().redis
    if redis:exists(cache_key) == 1 then
        redis:hset(cache_key, "expires", tostring(ngx.time() - 1))
        return true
    else
        return false
    end
end


function serve(self)
    if not ngx.headers_sent then
        local res = self:get_response() -- or self:get_response("fetched")
        assert(res.status, "Response has no status.")

        -- Via header
        local via = "1.1 " .. visible_hostname() .. " (ledge/" .. _VERSION .. ")"
        if  (res.header["Via"] ~= nil) then
            res.header["Via"] = via .. ", " .. res.header["Via"]
        else
            res.header["Via"] = via
        end

        -- X-Cache header
        -- Don't set if this isn't a cacheable response. Set to MISS is we fetched.
        local ctx = self:ctx()
        if not ctx.event_history["response_not_cacheable"] then
            local x_cache = "HIT from " .. visible_hostname()
            if ctx.state_history["fetching"] then
                x_cache = "MISS from " .. visible_hostname()
            end

            if res.header["X-Cache"] ~= nil then
                res.header["X-Cache"] = x_cache .. ", " .. res.header["X-Cache"]
            else
                res.header["X-Cache"] = x_cache
            end
        end

        self:emit("response_ready", res)

        -- If we have a 5xx or a 3/4xx and no body entity, exit allowing nginx config
        -- to generate a response.
        if res.status >= 500 or (res.status >= 300 and res.body == nil) then
            ngx.exit(res.status)
        end

        -- Otherwise send the response as normal.
        ngx.status = res.status

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        if res.body then
            ngx.print(res.body)
        end

        ngx.eof()
    end
end


function add_warning(self, code)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local warnings = {
        ["110"] = "Response is stale",
        ["214"] = "Transformation applied",
    }

    local header = code .. ' ' .. visible_hostname() .. ' "' .. warnings[code] .. '"'
    table.insert(res.header["Warning"], header)
end


function process_esi(self)
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
                return ngx.var.args or ""
            elseif var:sub(1, 7) == "$(HTTP_" then
                -- Look for a HTTP_var that matches
                local _, _, header = var:find("%$%(HTTP%_(.+)%)")
                if header then
                    return ngx.var["http_" .. header] or ""
                else
                    return ""
                end
            else
                return ""
            end
        end

        -- For every esi:vars block, substitute any number of variables found.
        body = ngx.re.gsub(body, "<esi:vars>(.*)</esi:vars>", function(var_block)
            return ngx.re.gsub(var_block[1],
                "\\$\\([A-Z_]+[{a-zA-Z\\.-~_%0-9}]*\\)",
                function(m)
                    return replace(m[0])
                end,
                "soj")
        end, "soj")

        -- Remove vars tags that are left over
        body = ngx.re.gsub(body, "(<esi:vars>|</esi:vars>)", "", "soj")

        -- Replace vars inline in any other esi: tags.
        body = ngx.re.gsub(body,
            "(<esi:.*)(\\$\\([A-Z_]+[{a-zA-Z\\.-~_%0-9}]*\\))(.*/>)",
            function(m)
                return m[1] .. replace(m[2]) .. m[3]
            end,
            "oj")
    end

    if res:has_esi_comment() then
        body = ngx.re.gsub(body, "(<!--esi(.*?)-->)", "$2", "soj")
    end

    if res:has_esi_remove() then
        body = ngx.re.gsub(body, "(<esi:remove>.*?</esi:remove>)", "", "soj")
    end

    if res:has_esi_include() then
        local esi_uris = {}
        for tag in ngx.re.gmatch(body, "<esi:include src=\"(.+)\".*/>", "oj") do
            table.insert(esi_uris, { tag[1] })
        end

        if table.getn(esi_uris) > 0 then
            -- Only works for relative URIs right now
            -- TODO: Extract hostname from absolute uris, and set the Host header accordingly.
            local esi_fragments = { ngx.location.capture_multi(esi_uris) }

            -- Create response objects.
            for i,fragment in ipairs(esi_fragments) do
                esi_fragments[i] = response:new(fragment)
            end

            -- Ensure that our cacheability is reduced shortest / newest from
            -- all fragments.
            res:minimise_lifetime(esi_fragments)

            body = ngx.re.gsub(body, "(<esi:include.*/>)", function(tag)
                return table.remove(esi_fragments, 1).body
            end, "ioj")
        end
    end

    if res.header["Content-Length"] then res.header["Content-Length"] = #body end
    res.body = body
    self:set_response(res)
    self:add_warning("214")
end

local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}


setmetatable(_M, class_mt)
