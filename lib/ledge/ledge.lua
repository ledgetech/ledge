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
        redis_database  = 0,
        redis_timeout   = nil,          -- Defaults to 60s or lua_socket_read_timeout
        redis_keepalive_timeout = nil,  -- Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- Defaults to 30 or lua_socket_pool_size
        keep_cache_for  = 86400 * 30,   -- Max time to Keep cache items past expiry + stale (sec)
        origin_mode     = ORIGIN_MODE_NORMAL,
        max_stale       = nil,          -- Warning: Violates HTTP spec
        enable_esi      = false,
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

    -- If we couldn't connect for any reason, redirect to the origin directly.
    -- This means if Redis goes down, the site stands a chance of still being up.
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


--[[
function accepts_stale_for(self)
    local stale = 0

    -- max_stale config overrides everything
    local max_stale = self:config_get("max_stale")
    if max_stale and max_stale > 0 then
        stale = max_stale
    end
   
    -- Otherwise we only serve stale if the request asks for it
    -- and the response permits it.
    local res = self:get_response(res)
   
    -- First check the response allows serving stale
    local ttl = res:stale_ttl()
    if ttl > 0 then
        return ttl + h_util.get_numeric_header_token(
            ngx.req.get_headers()["Cache-Control"], "max-stale"
        )
    else
        return 0
    end
end
]]--

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


-- Pre-transitions: Actions to always perform before transitioning.
--TODO: Perhaps actions need to be listed in an order? We can only have one right now.
pre_transitions = {
    exiting = { action = "redis_close" },
    fetching = { action = "fetch" },
    revalidating_upstream = { action = "fetch" },
    serving_not_modified = { action = "set_http_not_modified" },
    serving = { action = "serve" },
    serving_stale = { action = "serve" },
}


-- Events: Transition table, indexed by an event. 
-- Filter transitions by previous state "when", and run actions using "but_first". 
-- Requires at least "begin" to transition.
events = {
    init = {
        { begin = "checking_request", but_first = "redis_connect" }
    },

    purge_requested = {
        { begin = "purging" },
    },

    purged = {
        { begin = "exiting", but_first = "set_http_ok" },
    },

    nothing_to_purge = {
        { begin = "exiting", but_first = "set_http_not_found" },
    },

    cache_accepted = {
        { when = "checking_request", begin = "checking_cache", 
            but_first = "read_cache" },
        { when = "revalidating_locally", begin = "serving" }
    },

    cache_not_accepted = {
        { begin = "checking_can_fetch" }
    },

    cache_missing = {
        { begin = "checking_can_fetch", but_first = "remove_client_validators" }
    },

    cache_expired = {
        { when = "checking_cache", begin = "checking_can_serve_stale" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch", 
            but_first = "remove_client_validators" }
    },

    cache_valid = {
        { when = "checking_cache", begin = "considering_revalidation" }
    },

    can_fetch = {
        { begin = "fetching" }
    },

    response_fetched = {
        { begin = "updating_cache" }
    },

    response_cacheable = {
        { after = "revalidating_in_background", begin = "exiting", but_first = "save_to_cache" },
        { begin = "serving", but_first = "save_to_cache" },
    },

    response_not_cacheable = {
        { after = "revalidating_in_background", begin = "exiting", 
            but_first = "delete_from_cache" },
        { begin = "serving", but_first = "delete_from_cache" },
    },

    response_body_missing = {
        { after = "revalidating_in_background", begin = "exiting" },
        { begin = "serving" },
    },

    must_revalidate = {
        { when = "considering_revalidation", begin = "considering_local_revalidation" },
        { when = "considering_local_revalidation", begin = "revalidating_upstream",
            but_first = "add_validators_from_cache" },
    },

    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    not_modified = {
        { when = "revalidating_locally", begin = "serving_not_modified" },
        { when = "re_revalidating_locally", begin = "serving_not_modified" },
        --{ when = "revalidating_upstream", begin = "re_revalidating_locally" },
        -- TODO: Add in re-revalidation. Current tests aren't expecting this.
    },

    modified = {
        { when = "revalidating_locally", begin = "revalidating_upstream", 
            but_first = "add_validators_from_cache" },
        { when = "re_revalidating_locally", begin = "serving" },
    },

    can_serve = {
        { begin = "serving" }
    },

    serve_stale = {
        { when = "checking_can_serve_stale", begin = "serving_stale",
            but_first = "add_stale_warning" }
    },

    served = {
        { when = "serving_stale", begin = "checking_can_fetch" },
        { begin = "exiting" },
    },

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


-- Actions: Associate module functions callable by the state machine.
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
        return self:remove_client_validators()
    end,

    add_validators_from_cache = function(self)
        return self:add_validators_from_cache()
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


-- Decision states: Represented as functions which should simply make a decision, 
-- and return calling self:e with the event that has occurred.
-- Place any further logic in actions triggered by the transition table.
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

        return self:e "can_fetch"
    end,

    fetching = function(self)
        local res = self:get_response()

        if res.status == ngx.HTTP_NOT_MODIFIED then
            return self:e "can_serve"
        else
            return self:e "response_fetched"
        end
    end,

    purging = function(self)
        if self:delete_from_cache() > 0 then
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
            return self:e "can_serve"
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
            return self:e "can_serve"
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

    serving = function(self)
        return self:e "served"
    end,

    serving_not_modified = function(self)
        return self:e "served"
    end,

    serving_stale = function(self)
        -- TODO: Does looping around like this make sense?
        -- In fact, does can_serve and serve_stale make sense? Is "ready_to_serve" clearer?
        return self:e "served"
    end,

    exiting = function(self)
        ngx.exit(ngx.status)
    end,
}


function t(self, state)
    local ctx = self:ctx()

    -- Check for any transition pre-tasks
    local pre_t = self.pre_transitions[state]
    if pre_t and (pre_t["from"] == nil or ctx.current_state == pre_t["from"]) then
        ngx.log(ngx.NOTICE, "#t: " .. pre_t["action"])
        self.actions[pre_t["action"]](self)
    end

    ngx.log(ngx.NOTICE,"#t: " .. state)

    ctx.state_history[state] = true
    ctx.current_state = state
    return self.states[state](self)
end


function e(self, event)
    ngx.log(ngx.NOTICE, "#e: " .. event)

    local ctx = self:ctx()
    ctx.event_history[event] = true
    
    for _, trans in ipairs(self.events[event]) do
        if trans["when"] == nil or trans["when"] == ctx.current_state then
            if not trans["after"] or ctx.state_history[trans["after"]] then 
                if trans["but_first"] then
                    ngx.log(ngx.NOTICE, "#a: " .. trans["but_first"])
                    self.actions[trans["but_first"]](self)
                end

                return self:t(trans["begin"])
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
    end

    -- No cache entry for this key
    if #cache_parts == 0 then
        return nil
    end

    local ttl = nil
    local time_in_cache = 0
    local time_since_generated = 0

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
            res.esi.has_esi_comment = not not cache_parts[i + 1]
        elseif cache_parts[i] == "esi_remove" then
            res.esi.has_esi_remove = not not cache_parts[i + 1]
        elseif cache_parts[i] == "esi_include" then
            res.esi.has_esi_include = not not cache_parts[i + 1]
        elseif cache_parts[i] == "esi_vars" then
            res.esi.has_esi_vars = not not cache_parts[i + 1]
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


function remove_client_validators(self)
    ngx.req.set_header("If-Modified-Since", nil)
    ngx.req.set_header("If-None-Match", nil)
end


function add_validators_from_cache(self)
    local cached_res = self:get_response()

    -- TODO: Patch OpenResty to accept additional headers for subrequests.
    ngx.req.set_header("If-Modified-Since", cached_res.header["Last-Modified"])
    ngx.req.set_header("If-None-Match", cached_res.header["Etag"])
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
        redis:hmset(cache_key(self),
            'esi_comment', tostring(res:has_esi_comment()),
            'esi_remove', tostring(res:has_esi_remove()),
            'esi_include', tostring(res:has_esi_include()),
            'esi_vars', tostring(res:has_esi_vars())
        )
    end

    redis:expire(cache_key(self), ttl + tonumber(self:config_get("keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, uri)

    -- Run transaction
    local replies, err = redis:exec()
    if not replies then
        ngx.log(ngx.ERR, "Failed to save cache item: " .. err)
    end
end


function delete_from_cache(self)
    return self:ctx().redis:del(self:cache_key())
end


function serve(self)
    -- TODO: Would be nice to not just wedge this in here...
    if self:config_get("enable_esi") then
        self:process_esi()
    end

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
    local transformed = false

    -- Only perform trasnformations if we know there's work to do. This is determined
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

        transformed = true
    end

    if res:has_esi_comment() then
        body = ngx.re.gsub(body, "(<!--esi(.*?)-->)", "$2", "soj")
        transformed = true
    end

    if res:has_esi_remove() then
        body = ngx.re.gsub(body, "(<esi:remove>.*?</esi:remove>)", "", "soj")
        transformed = true
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
        transformed = true
    end

    if transformed then
        if res.header["Content-Length"] then res.header["Content-Length"] = #body end
        res.body = body
        self:set_response(res)
        self:add_warning("214")
    end
end


local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}


setmetatable(_M, class_mt)
