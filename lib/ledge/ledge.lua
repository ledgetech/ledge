module("ledge.ledge", package.seeall)

_VERSION = '0.04'


-- Origin modes, for serving stale content during maintenance periods or emergencies.
ORIGIN_MODE_BYPASS  = 1 -- Never goes to the origin, serve from cache where possible or 503.
ORIGIN_MODE_AVOID   = 2 -- Avoids going to the origin, serving from cache where possible.
ORIGIN_MODE_NORMAL  = 4 -- Assume the origin is happy, use at will.

-- Origin actions
ORIGIN_ACTION_NONE      = -1 -- No need for the origin (cache HIT).
ORIGIN_ACTION_FETCHED   = 1 -- Went to the origin.
ORIGIN_ACTION_COLLAPSED = 2 -- Waited on a similar request to the origin, and shared the reponse.


local resty_redis = require("resty.redis")
local response = require("ledge.response")
local class = ledge.ledge
local mt = { __index = class }


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
        keep_cache_for = 86400 * 30,    -- Max time to Keep cache items past expiry + stale (sec)
        origin_mode = ORIGIN_MODE_NORMAL,
    }

    return setmetatable({ config = config }, mt)
end


function run(self)
    -- Off we go then.. enter the ST_INIT state.
    self:ST_INIT()
end


-- UTILITIES --------------------------------------------------

-- A safe place in ngx.ctx for the current module instance (self).
function ctx(self)
    local id = tostring(self)
    if not ngx.ctx[id] then
        ngx.ctx[id] = {
            events = {},
            config = {},
            state_history = {},
        }
    end
    return ngx.ctx[id]
end


-- Keeps track of the transition history.
function transition(self, state)
    table.insert(self:ctx().state_history, state)
end


function relative_uri()
    return ngx.var.uri .. ngx.var.is_args .. (ngx.var.query_string or "")
end


function full_uri()
    return ngx.var.scheme .. '://' .. ngx.var.host .. relative_uri()
end


function redis_connect(self)
    -- Connect to Redis. The connection is kept alive later.
    self:ctx().redis = resty_redis:new()
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


function set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end


function get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


function cache_key(self)
    if not self.ctx().cache_key then 
        -- Generate the cache key, from a given or default spec. The default is:
        -- ledge:cache_obj:GET:http:example.com:/about:p=3&q=searchterms
        local key_spec = self:config_get("cache_key_spec") or {
            ngx.var.request_method,
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
    return self:ctx().config[param] or self.config[param] or nil
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


-- STATES ------------------------------------------------------


function ST_INIT(self)
    self:transition("ST_INIT")
    self:redis_connect()

    if self:request_accepts_cache() then
        return self:ST_ACCEPTING_CACHE()
    else
        return self:ST_FETCHING()
    end
end


function ST_ACCEPTING_CACHE(self)
    self:transition("ST_ACCEPTING_CACHE")

    local res = self:read_from_cache()
    
    if not res or res.remaining_ttl <= 0 then
        return self:ST_FETCHING()
    else
        self:set_response(res)
        return self:ST_USING_CACHE()
    end
end


function ST_USING_CACHE(self)
    self:transition("ST_USING_CACHE")

    -- TODO: Validation

    return self:ST_SERVING()
end


function ST_FETCHING(self)
    self:transition("ST_FETCHING")

    local res = self:fetch_from_origin()
    self:set_response(res)
    if res:is_cacheable() then
        return self:ST_SAVING()
    else
        return self:ST_DELETING()
    end
end


function ST_SAVING(self)
    self:transition("ST_SAVING")
    self:save_to_cache(self:get_response())
    return self:ST_SERVING()
end


function ST_DELETING(self)
    self:transition("ST_DELETING")
    self:delete_from_cache()
    return self:ST_SERVING()
end


function ST_SERVING(self)
    self:transition("ST_SERVING")
    self:redis_close()
    return self:serve()
end


-- ACTIONS ---------------------------------------------------------


function read_from_cache(self)
    local res = response:new()

    -- Fetch from Redis, pipeline to reduce overhead
    local cache_parts, err = self:ctx().redis:hgetall(cache_key(self))
    if not cache_parts then
        ngx.log(ngx.ERR, "Failed to read cache item: " .. err)
    end

    local ttl = nil
    local time_in_cache = 0

    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        if cache_parts[i] == 'body' then
            res.body = cache_parts[i+1]
        elseif cache_parts[i] == 'status' then
            res.status = tonumber(cache_parts[i+1])
        elseif cache_parts[i] == 'expires' then
            res.remaining_ttl = tonumber(cache_parts[i+1]) - ngx.time()
        elseif cache_parts[i] == 'saved_ts' then
            time_in_cache = ngx.time() - tonumber(cache_parts[i+1])
        else
            -- Everything else will be a header, with a h: prefix.
            local _, _, header = cache_parts[i]:find('h:(.*)')
            if header then
                res.header[header] = cache_parts[i+1]
            end
        end
    end

    -- Calculate the Age header
    if res.header["Age"] then
        -- We have end-to-end Age headers, add our time_in_cache.
        res.header["Age"] = tonumber(res.header["Age"]) + time_in_cache
    elseif res.header["Date"] then
        -- We have no advertised Age, use the Date to generate it.
        res.header["Age"] = ngx.time() - ngx.parse_http_time(res.header["Date"])
    end

    --emit("cache_accessed", res)

    return res
end


-- Fetches a resource from the origin server.
function fetch_from_origin(self)
    local res = response:new()
    --emit("origin_required")

    -- If we're in BYPASS mode, we can't fetch anything.
    if self:config_get("origin_mode") == ORIGIN_MODE_BYPASS then
        res.status = ngx.HTTP_SERVICE_UNAVAILABLE
        return res
    end

    local origin = ngx.location.capture(self:config_get("origin_location")..relative_uri(), {
        method = ngx['HTTP_' .. ngx.req.get_method()], -- Method as ngx.HTTP_x constant.
        body = ngx.req.get_body_data(),
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
    --emit("before_save", res)

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
            table.insert(h, 'h:'..header)
            table.insert(h, header_value)
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
        'saved_ts', ngx.time(),
        unpack(h)
    )
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
    self:ctx().redis:del(self:cache_key())
end


function serve(self)
    if not ngx.headers_sent then
        local res = self:get_response()
        assert(res.status, "Response has no status.")

        -- Via header
        local via = "1.1 " .. ngx.var.hostname .. " (ledge/" .. _VERSION .. ")"
        if  (res.header["Via"] ~= nil) then
            res.header["Via"] = via .. ", " .. res.header["Via"]
        else
            res.header["Via"] = via
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


-- to prevent casual use of module globals
getmetatable(ledge.ledge).__newindex = function(t, k, v)
    error("Attempt to write to undeclared variable '" .. k .. "': " .. debug.traceback())
end
