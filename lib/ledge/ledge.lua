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
    
-- Can be overriden during init_by_lua with ledge.set(param, value).
local global_config = {
    origin_location = "/__ledge_origin",
    redis_host      = "127.0.0.1",
    redis_port      = 6379,
    redis_socket    = nil,
    redis_database  = 0,
    redis_timeout   = nil,          -- Defaults to 60s or lua_socket_read_timeout
    redis_keepalive_timeout = nil,  -- Defaults to 60s or lua_socket_keepalive_timeout
    redis_keepalive_poolsize = nil, -- Defaults to 30 or lua_socket_pool_size
    keep_cache_for = 86400 * 30,    -- Max time to Keep cache items past expiry + stale (seconds)
    origin_mode = ORIGIN_MODE_NORMAL,
}


function new(self)
    if ngx.get_phase() ~= "init" then
        ngx.ctx.__ledge = {
            events = {},
            config = {},
        }
    end

    return setmetatable({ global_config = global_config }, mt)
end


function go(self)
    redis_connect(self)

    if request_accepts_cache(self) then
        local res = read(self)
        if not res or not res.status then
            res = fetch(self)
            ngx.ctx.__ledge.res = res
            save(self, es)
        else
            ngx.ctx.__ledge.res = res
        end
        -- etc.
    else
        local origin_res = fetch(self)
        ngx.ctx.__ledge.res = origin_res
        save(self, origin_res)
        -- etc.
    end

    local res = ngx.ctx.__ledge.res
    prepare_response(res)

    emit("response_ready", res)
    send(res)
    redis_close(self)
end


function send(res)
    if not ngx.headers_sent then
        assert(res.status, "Response has no status.")

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


function relative_uri()
    return ngx.var.uri .. ngx.var.is_args .. (ngx.var.query_string or "")
end


function full_uri()
    return ngx.var.scheme .. '://' .. ngx.var.host .. relative_uri()
end


function request_accepts_cache(self)
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then 
        return false 
    end

    -- Ignore the client requirements if we're not in "NORMAL" mode.
    if get(self, "origin_mode") < ORIGIN_MODE_NORMAL then 
        return true 
    end

    -- Check for no-cache
    local h = ngx.req.get_headers()
    if h["Cache-Control"] == "no-cache" or h["Pragma"] == "no-cache" then
        return false
    end

    return true
end


function response_is_cacheable(res)
    local nocache_headers = {
        ["Pragma"] = { "no-cache" },
        ["Cache-Control"] = {
            "no-cache", 
            "no-store", 
            "private",
        }
    }

    for k,v in pairs(nocache_headers) do
        for i,h in ipairs(v) do
            if (res.header[k] and res.header[k] == h) then
        --        res.cache_state = CACHE_STATE_PRIVATE
                return false
            end
        end
    end

    if response_ttl(res) > 0 then
        return true
    else
      --  res.cache_state = CACHE_STATE_PRIVATE
        return false
    end
end


function response_ttl(res)
    -- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
    -- and finally Expires: HTTP_TIMESTRING.
    if res.header["Cache-Control"] then
        for _,p in ipairs({ "s%-maxage", "max%-age" }) do
            for h in res.header["Cache-Control"]:gmatch(p .. "=\"?(%d+)\"?") do 
                return tonumber(h)
            end
        end
    end

    -- Fall back to Expires.
    if res.header["Expires"] then 
        local time = ngx.parse_http_time(res.header["Expires"])
        if time then return time - ngx.time() end
    end

    return 0
end


function redis_connect(self)
    -- Connect to Redis. The connection is kept alive later.
    ngx.ctx.redis = resty_redis:new()
    if get(self, "redis_timeout") then ngx.ctx.redis:set_timeout(get(self, "redis_timeout")) end

    local ok, err = ngx.ctx.redis:connect(
        get(self, "redis_socket") or get(self, "redis_host"), 
        get(self, "redis_port")
    )

    -- If we couldn't connect for any reason, redirect to the origin directly.
    -- This means if Redis goes down, the site stands a chance of still being up.
    if not ok then
        ngx.log(ngx.WARN, err .. ", internally redirecting to the origin")
        return ngx.exec(get(self, "origin_location")..relative_uri())
    end

    -- redis:select always returns OK
    if get(self, "redis_database") > 0 then ngx.ctx.redis:select(get(self, "redis_database")) end
end


function redis_close(self)
    -- Keep the Redis connection based on keepalive settings.
    local ok, err = nil
    if get(self, "redis_keepalive_timeout") then
        if get(self, "redis_keepalive_pool_size") then
            ok, err = ngx.ctx.redis:set_keepalive(
                get(self, "redis_keepalive_timeout"), 
                get(self, "redis_keepalive_pool_size")
            )
        else
            ok, err = ngx.ctx.redis:set_keepalive(get(self, "redis_keepalive_timeout"))
        end
    else
        ok, err = ngx.ctx.redis:set_keepalive()
    end

    if not ok then
        ngx.log(ngx.WARN, "couldn't set keepalive, "..err)
    end
end


-- Reads an item from cache
--
-- @param	table   req
-- @param   table   res
-- @return	number  ttl
function read(self)
    local res = response:new()
    res.state = res.RESPONSE_STATE_SUBZERO

    -- Fetch from Redis, pipeline to reduce overhead
    local cache_parts, err = ngx.ctx.redis:hgetall(cache_key(self))
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
            ttl = tonumber(cache_parts[i+1]) - ngx.time()
            -- Return nil on cache miss
            if get(self, "origin_mode") == ORIGIN_MODE_NORMAL and ttl <= 0 then 
                res.cache_state = CACHE_STATE_COLD
                return nil 
            else
                -- TODO: Check for stale
                res.cache_state = CACHE_STATE_HOT
            end
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

    -- If our response is older than the request max-age, we ignore cache
    --[[
    if req.max_age and req.max_age < res.header["Age"] then
        res.cache_state = CACHE_STATE_RELOADED
        return nil
    end
    ]]--

    --[[
    MOVE TO must_revalidate() ?

    -- If we must-revalidate, set the ttl to 0 to trigger a fetch.
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("must%-revalidate") then
        -- TODO: To be useful here, we should issue a conditional GET to the origin, if we get 
        -- a 304, return the current response (with a 200, since this revalidation was server, 
        -- not client specififed). This allows us to revalidate but not transfer the body
        -- from a distant origin without needing too.
        res.cache_state = CACHE_STATE_REVALIDATED
        return nil
    end
    --]]

    emit("cache_accessed", res)

    return res -- return ttl <-- what was this for?
end


-- Stores an item in cache
--
-- @param	table       The HTTP response object to store
-- @return	boolean|nil, status     Saved state or nil, ngx.capture status on error.
function save(self, res)
    if not response_is_cacheable(res) then
        return 0 -- Not cacheable, but no error
    end

    emit("before_save", res)

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

    local redis = ngx.ctx.redis

    -- Save atomically
    redis:multi()

    -- Delete any existing data, to avoid accidental hash merges.
    redis:del(cache_key(self))

    local ttl = response_ttl(res)
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
    redis:expire(cache_key(self), ttl + tonumber(get(self, "keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, uri)

    -- Run transaction
    local replies, err = redis:exec()
    if not replies then
        ngx.log(ngx.ERR, "Failed to save cache item: " .. err)
    end
end


-- Fetches a resource from the origin server.
function fetch(self)
    local res = response:new()
    emit("origin_required")

    -- If we're in BYPASS mode, we can't fetch anything.
    if get(self, "origin_mode") == ORIGIN_MODE_BYPASS then
        res.status = ngx.HTTP_SERVICE_UNAVAILABLE
        return res
    end
        
    res.origin_action = ORIGIN_ACTION_FETCHED

    local origin = ngx.location.capture(get(self, "origin_location")..relative_uri(), {
        method = ngx['HTTP_' .. ngx.req.get_method()], -- Method as ngx.HTTP_x constant.
        body = ngx.req.get_body_data(),
    })

    res.status = origin.status
    -- Merge headers in rather than wipe out the res.headers table)
    for k,v in pairs(origin.header) do
        res.header[k] = v
    end
    res.body = origin.body

    -- Could not proxy for some reason
    if res.status >= 500 then
        return res
    else
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned 
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx.parse_http_time(res.header["Date"]) then
            ngx.log(ngx.WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx.http_time(ngx.time())
        end

        -- A nice opportunity for post-fetch / pre-save work.
        emit("origin_fetched", res)

        -- Save
        -- save(res) Do this outside??
        return res
    end
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
--[[
function fetch_background(req, res)
    ngx.ctx.redis:publish('revalidate', req.uri_full)
end
]]


function prepare_response(res)
    local hostname = ngx.var.hostname

    -- Via header
    local via = "1.1 " .. hostname .. " (ledge/" .. _VERSION .. ")"
    if  (res.header["Via"] ~= nil) then
        res.header["Via"] = via .. ", " .. res.header["Via"]
    else
        res.header["Via"] = via
    end

--[[

    -- X-Cache header
    local cache = "MISS"
    if res.response_state > response.RESPONSE_STATE_COLD then
        cache = "HIT"
    end
    ]]--    
    -- X-Ledge-Cache headers
    local cache_state = cache_state_string(res.cache_state)

    -- For cachable responses, we add X-Cache and X-Ledge-Cache headers
    -- appending to upstream headers where necessary.
--[[
    if res.cache_state > CACHE_STATE_PRIVATE then
        if res.header["X-Cache"] then
            res.header["X-Cache"] = cache.." from "..hostname..", "..res.header["X-Cache"]
        else
            res.header["X-Cache"] = cache.." from "..hostname
        end

        if res.header["X-Ledge-Cache"] then
            res.header["X-Ledge-Cache"] = cache_state.." from "..hostname..", "..res.header["X-Ledge-Cache"]
        else
            res.header["X-Ledge-Cache"] = cache_state.." from "..hostname
        end
    end
    -- Log variables. These must be initialized in nginx.conf
    if ngx.var.ledge_cache then
        ngx.var.ledge_cache = cache
    end

    if ngx.var.ledge_cache_state then
        ngx.var.ledge_cache_state = cache_state
    end

    if ngx.var.ledge_origin_action then
        ngx.var.ledge_origin_action = origin_action_string(res.origin_action)
    end

    if ngx.var.ledge_version then
        ngx.var.ledge_version = "ledge/" .. _VERSION
    end
]]--
end


function cache_state_string(state)
    return "TODO"
    --[[
    if state == CACHE_STATE_PRIVATE then
        return "PRIVATE"
    elseif state == CACHE_STATE_SUBZERO then
        return "SUBZERO"
    elseif state == CACHE_STATE_COLD then
        return "COLD"
    elseif state == CACHE_STATE_WARM then
        return "WARM"
    elseif state == CACHE_STATE_HOT then
        return "HOT"
    elseif state == CACHE_STATE_REVALIDATED then
        return "REVALIDATED"
    elseif state == CACHE_STATE_RELOADED then
        return "RELOADED"
    else
        ngx.log(ngx.WARN, "unknown cache state: " .. tostring(state))
        return ""
    end
    ]]--
end


function origin_action_string(action)
    if action == ORIGIN_ACTION_NONE then
        return "NONE"
    elseif action == ORIGIN_ACTION_FETCHED then
        return "FETCHED"
    else
        ngx.log(ngx.WARN, "unknown origin action: " .. tostring(action))
        return ""
    end
end


function cache_key(self)
    if not ngx.ctx.__ledge.cache_key then 
        -- Generate the cache key, from a given or default spec. The default is:
        -- ledge:cache_obj:GET:http:example.com:/about:p=3&q=searchterms
        local key_spec = get(self, "cache_key_spec") or {
            ngx.var.request_method,
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
            ngx.var.args,
        }
        table.insert(key_spec, 1, "cache_obj")
        table.insert(key_spec, 1, "ledge")
        ngx.ctx.__ledge.cache_key = table.concat(key_spec, ":")
    end
    return ngx.ctx.__ledge.cache_key
end


-- Set a config parameter
function set(self, param, value)
    if ngx.get_phase() == "init" then
        self.global_config[param] = value
    else
        ngx.ctx.__ledge.config[param] = value
    end
end


-- Gets a config parameter. 
function get(self, param)
    return ngx.ctx.__ledge.config[param] or self.global_config[param] or nil
end


-- Attach handler to an event
-- 
-- @param   string      The event identifier
-- @param   function    The event handler
-- @return  void
function bind(self, event, callback)
    if not ngx.ctx.__ledge then ngx.ctx.__ledge = { events = {}, config = {} } end
    if not ngx.ctx.__ledge.events[event] then ngx.ctx.__ledge.events[event] = {} end
    table.insert(ngx.ctx.__ledge.events[event], callback)
end


-- Broadcast an event
--
-- @param   string  The event identifier
-- @param   table   Response environment
-- @return  void
function emit(event, res)
    for _, handler in ipairs(ngx.ctx.__ledge.events[event] or {}) do
        if type(handler) == "function" then
            handler(res)
        end
    end
end


-- Metatable
--
-- To avoid race conditions, we specify a shared metatable and detect any 
-- attempt to accidentally declare a field in this module from outside.
setmetatable(ledge, {})
getmetatable(ledge).__newindex = function(table, key, val) 
    error('Attempt to write to undeclared variable "'..key..'": '..debug.traceback()) 
end
