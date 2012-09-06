module("ledge.ledge", package.seeall)

_VERSION = '0.04'

-- Cache states
CACHE_STATE_PRIVATE     = -12
CACHE_STATE_IGNORED     = -11
CACHE_STATE_REVALIDATED = -10
CACHE_STATE_SUBZERO     = -1
CACHE_STATE_COLD        = 0
CACHE_STATE_WARM        = 1
CACHE_STATE_HOT         = 2

-- Origin modes, for serving stale content during maintenance periods or emergencies.
ORIGIN_MODE_BYPASS  = 1 -- Never goes to the origin, serve from cache where possible or 503.
ORIGIN_MODE_AVOID   = 2 -- Avoids going to the origin, serving from cache where possible.
ORIGIN_MODE_NORMAL  = 4 -- Assume the origin is happy, use at will.

-- Origin actions
ORIGIN_ACTION_NONE      = -1 -- No need for the origin (cache HIT).
ORIGIN_ACTION_FETCHED   = 1 -- Went to the origin.
ORIGIN_ACTION_COLLAPSED = 2 -- Waited on a similar request to the origin, and shared the reponse.

-- Configuration defaults.
-- Can be overriden during init_by_lua with ledge.set(param, value).
local g_config = {
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


local resty_redis = require("resty.redis")

-- Resty rack interface
function call()
    if not ngx.ctx.ledge then create_ledge_ctx() end

    return function(req, res)

        -- First lets introduce some utility functions to our rack req/res environments.

        req.accepts_cache = function()
            if req.method ~= "GET" and req.method ~= "HEAD" then return false end
            
            -- Ignore the client requirements if we're not in "NORMAL" mode.
            if get("origin_mode") < ORIGIN_MODE_NORMAL then return true end

            if req.header["Cache-Control"] == "no-cache" or req.header["Pragma"] == "no-cache" then
                res.cache_state = CACHE_STATE_IGNORED
                return false
            end

            if req.header["Cache-Control"] then
                local max_age = req.header["Cache-Control"]:match("max%-age=\"?(%d+)\"?")
                if max_age then
                    max_age = tonumber(max_age)
                    -- max-age=0 means we wish to ignore cache completely
                    if max_age == 0 then
                        res.cache_state = CACHE_STATE_IGNORED
                        return false
                    else
                        -- We'll test this against Age when reading from cache.
                        req.max_age = max_age
                    end
                end
            end

            return true
        end

        res.cacheable = function()
            local nocache_headers = {
                ["Pragma"] = { "no-cache" },
                ["Cache-Control"] = {
                    "no-cache", 
                    "no-store", 
                    "private",
                }
            }

            for k,v in pairs(nocache_headers) do
                for i,header in ipairs(v) do
                    if (res.header[k] and res.header[k] == header) then
                        res.cache_state = CACHE_STATE_PRIVATE
                        return false
                    end
                end
            end

            if res.ttl() > 0 then
                return true
            else
                res.cache_state = CACHE_STATE_PRIVATE
                return false
            end
        end

        -- The cache ttl used for saving.
        res.ttl = function()
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

        res.cache_state = CACHE_STATE_PRIVATE
        res.origin_action = ORIGIN_ACTION_NONE

        redis_connect(req, res)

        -- Try to read from cache. 
        if not read(req, res) then
            -- We must revalidate
            if not fetch(req, res) then
                -- Some kind of error has occurred. Clean up and pass the proxies error on.
                redis_close()
                return
            end
        end
        
        -- Modify / add to response headers.
        prepare_response(req, res)

        emit("response_ready", req, res)
        
        redis_close()
    end
end


function redis_connect(req, res)
    -- Connect to Redis. The connection is kept alive later.
    ngx.ctx.redis = resty_redis:new()
    if get("redis_timeout") then ngx.ctx.redis:set_timeout(get("redis_timeout")) end

    local ok, err = ngx.ctx.redis:connect(
        get("redis_socket") or get("redis_host"), 
        get("redis_port")
    )

    -- If we couldn't connect for any reason, redirect to the origin directly.
    -- This means if Redis goes down, the site stands a chance of still being up.
    if not ok then
        ngx.log(ngx.WARN, err .. ", internally redirecting to the origin")
        return ngx.exec(get("origin_location")..req.uri_relative)
    end

    -- redis:select always returns OK
    if get("redis_database") > 0 then ngx.ctx.redis:select(get("redis_database")) end
end


function redis_close()
    -- Keep the Redis connection based on keepalive settings.
    local ok, err = nil
    if get("redis_keepalive_timeout") then
        if get("redis_keepalive_pool_size") then
            ok, err = ngx.ctx.redis:set_keepalive(
                get("redis_keepalive_timeout"), 
                get("redis_keepalive_pool_size")
            )
        else
            ok, err = ngx.ctx.redis:set_keepalive(get("redis_keepalive_timeout"))
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
function read(req, res)
    if not req.accepts_cache() then return nil end

    res.cache_state = CACHE_STATE_SUBZERO

    -- Fetch from Redis, pipeline to reduce overhead
    local cache_parts, err = ngx.ctx.redis:hgetall(cache_key())
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
            if get("origin_mode") == ORIGIN_MODE_NORMAL and ttl <= 0 then 
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
    if req.max_age and req.max_age < res.header["Age"] then
        res.cache_state = CACHE_STATE_IGNORED
        return nil
    end

    -- If we must-revalidate, set the ttl to 0 to trigger a fetch.
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("must%-revalidate") then
        -- TODO: To be useful here, we should issue a conditional GET to the origin, if we get 
        -- a 304, return the current response (with a 200, since this revalidation was server, 
        -- not client specififed). This allows us to revalidate but not transfer the body
        -- from a distant origin without needing too.
        res.cache_state = CACHE_STATE_IGNORED
        return nil
    end

    emit("cache_accessed", req, res)

    return ttl
end


-- Stores an item in cache
--
-- @param	table       The HTTP response object to store
-- @return	boolean|nil, status     Saved state or nil, ngx.capture status on error.
function save(req, res)
    if not res.cacheable() then
        return 0 -- Not cacheable, but no error
    end

    emit("before_save", req, res)

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
    redis:del(cache_key())

    local ttl = res.ttl()
    local expires = ttl + ngx.time()

    redis:hmset(cache_key(), 
        'body', res.body, 
        'status', res.status,
        'uri', req.uri_full,
        'expires', expires,
        'saved_ts', ngx.time(),
        unpack(h)
    )
    redis:expire(cache_key(), ttl + tonumber(get("keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, req.uri_full)

    -- Run transaction
    local replies, err = redis:exec()
    if not replies then
        ngx.log(ngx.ERR, "Failed to save cache item: " .. err)
    end
end


-- Fetches a resource from the origin server.
function fetch(req, res)
    emit("origin_required", req, res)

    -- If we're in BYPASS mode, we can't fetch anything.
    if get("origin_mode") == ORIGIN_MODE_BYPASS then
        res.status = ngx.HTTP_SERVICE_UNAVAILABLE
        return nil
    end
        
    res.origin_action = ORIGIN_ACTION_FETCHED

    local origin = ngx.location.capture(get("origin_location")..req.uri_relative, {
        method = ngx['HTTP_' .. req.method], -- Method as ngx.HTTP_x constant.
        body = req.body,
    })

    res.status = origin.status
    -- Merge headers in rather than wipe out the res.headers table)
    for k,v in pairs(origin.header) do
        res.header[k] = v
    end
    res.body = origin.body

    -- Could not proxy for some reason
    if res.status >= 500 then
        return nil
    else
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned 
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx.parse_http_time(res.header["Date"]) then
            ngx.log(ngx.WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx.http_time(ngx.time())
        end

        -- A nice opportunity for post-fetch / pre-save work.
        emit("origin_fetched", req, res)

        -- Save
        save(req, res)
        return true
    end
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
function fetch_background(req, res)
    ngx.ctx.redis:publish('revalidate', req.uri_full)
end


function prepare_response(req, res)
    local hostname = ngx.var.hostname

    -- Via header
    local via = "1.1 " .. hostname .. " (ledge/" .. _VERSION .. ")"
    if  (res.header["Via"] ~= nil) then
        res.header["Via"] = via .. ", " .. res.header["Via"]
    else
        res.header["Via"] = via
    end

    -- X-Cache header
    local cache = "MISS"
    if res.cache_state > CACHE_STATE_COLD then
        cache = "HIT"
    end
        
    -- X-Ledge-Cache headers
    local cache_state = cache_state_string(res.cache_state)

    -- For cachable responses, we add X-Cache and X-Ledge-Cache headers
    -- appending to upstream headers where necessary.
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
end


function cache_state_string(state)
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
    elseif state == CACHE_STATE_IGNORED then
        return "IGNORED"
    else
        ngx.log(ngx.WARN, "unknown cache state: " .. tostring(state))
        return ""
    end
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


function cache_key()
    if not ngx.ctx.ledge then create_ledge_ctx() end
    if not ngx.ctx.ledge.cache_key then 
        -- Generate the cache key, from a given or default spec. The default is:
        -- ledge:cache_obj:GET:http:example.com:/about:p=3&q=searchterms
        local key_spec = get("cache_key_spec") or {
            ngx.var.request_method,
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
            ngx.var.args,
        }
        table.insert(key_spec, 1, "cache_obj")
        table.insert(key_spec, 1, "ledge")
        ngx.ctx.ledge.cache_key = table.concat(key_spec, ":")
    end
    return ngx.ctx.ledge.cache_key
end


-- Set a config parameter
function set(param, value)
    if ngx.get_phase() == "init" then
        g_config[param] = value
    else
        if not ngx.ctx.ledge then create_ledge_ctx() end
        ngx.ctx.ledge.config[param] = value
    end
end


-- Gets a config parameter. 
function get(param)
    if not ngx.ctx.ledge then create_ledge_ctx() end
    return ngx.ctx.ledge.config[param] or g_config[param] or nil
end


-- Attach handler to an event
-- 
-- @param   string      The event identifier
-- @param   function    The event handler
-- @return  void
function bind(event, callback)
    if not ngx.ctx.ledge then create_ledge_ctx() end
    if not ngx.ctx.ledge.event[event] then ngx.ctx.ledge.event[event] = {} end
    table.insert(ngx.ctx.ledge.event[event], callback)
end


-- Broadcast an event
--
-- @param   string  The event identifier
-- @param   table   request environment
-- @param   table   response environment
-- @return  void
function emit(event, req, res)
    for _, handler in ipairs(ngx.ctx.ledge.event[event] or {}) do
        if type(handler) == "function" then
            handler(req, res)
        end
    end
end


-- Ensures we have tables ready for event registration and configuration settings
function create_ledge_ctx()
    ngx.ctx.ledge = {
        event = {},
        config = {}
    }
end


-- Metatable
--
-- To avoid race conditions, we specify a shared metatable and detect any 
-- attempt to accidentally declare a field in this module from outside.
setmetatable(ledge, {})
getmetatable(ledge).__newindex = function(table, key, val) 
    error('Attempt to write to undeclared variable "'..key..'": '..debug.traceback()) 
end
