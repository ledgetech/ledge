module("ledge.ledge", package.seeall)

_VERSION = '0.02'

local resty_redis = require("resty.redis")

-- Cache states 
local cache_states= {
    SUBZERO = 1, -- We don't know anything about this URI. Either first hit or not cacheable.
    COLD    = 2, -- Previosuly cacheable, expired and beyond stale. Revalidate.
    WARM    = 3, -- Previously cacheable, cached but stale. Serve and bg refresh.
    HOT     = 4, -- Cached. Serve.
}

-- Proxy actions
local proxy_actions = {
    FETCHED     = 1, -- Went to the origin.
    COLLAPSED   = 2, -- Waited on a similar request to the origin, and shared the reponse.
}

local options = {}

-- Resty rack interface
function call(o)
    if not ngx.ctx.ledge then create_ledge_ctx() end
    options = o

    return function(req, res)

        -- First lets introduce some utility functions to our rack req/res environments.

        req.accepts_cache = function()
            if ngx["HTTP_"..req.method] ~= ngx.HTTP_GET then return false end
            if req.header["Cache-Control"] == "no-cache" or req.header["Pragma"] == "no-cache" then
                return false
            end
            return true
        end

        res.cacheable = function()
            local nocache_headers = {
                ["Pragma"] = { "no-cache" },
                ["Cache-Control"] = {
                    "no-cache", 
                    "must-revalidate", 
                    "no-store", 
                    "private",
                }
            }

            for k,v in pairs(nocache_headers) do
                for i,header in ipairs(v) do
                    if (res.header[k] and res.header[k] == header) then
                        return false
                    end
                end
            end

            return res.ttl() > 0 or false
        end

        -- The Expires header as a unix timestamp
        res.expires_timestamp = function()
            if res.header["Expires"] then return ngx.parse_http_time(res.header["Expires"]) end
        end

        -- The cache ttl used for saving.
        res.ttl = function()
            local expires_ts = res.expires_timestamp()
            -- TODO: Reintroduce stale TTL from config
            if expires_ts then 
                return (expires_ts - ngx.time()) 
            else
                return 0
            end
        end

        -- Generate the cache key, from a given or default spec. The default is:
        -- ledge:cache_obj:GET:http:example.com:/about:p=3&q=searchterms
        if not ngx.ctx.ledge.config.cache_key_spec then
            ngx.ctx.ledge.config.cache_key_spec = {
                ngx.var.request_method,
                ngx.var.scheme,
                ngx.var.host,
                ngx.var.uri,
                ngx.var.args,
            }
        end
        table.insert(ngx.ctx.ledge.config.cache_key_spec, 1, "cache_obj")
        table.insert(ngx.ctx.ledge.config.cache_key_spec, 1, "ledge")
        ngx.ctx.ledge.cache_key = table.concat(ngx.ctx.ledge.config.cache_key_spec, ":")

        redis_connect()

        -- Try to read from cache. 
        if read(req, res) then
            res.state = cache_states.HOT
            set_headers(req, res)
        else
            -- Nothing in cache or the client can't accept a cached response. 
            -- TODO: Check for prior knowledge to determine probably cacheability?
            if not fetch(req, res) then
                redis_close()
                return -- Pass the proxied error on.
            else
                res.state = cache_states.SUBZERO
                set_headers(req, res)
            end
        end

        emit("response_ready", req, res)
        
        redis_close()
    end
end


function redis_connect()
    -- Connect to Redis. The connection is kept alive later.
    ngx.ctx.redis = resty_redis:new()
    if not options.redis then options.redis = {} end -- In case nothing has been set.
    ngx.ctx.redis:set_timeout(options.redis.timeout or 1000) -- Default to 1 sec

    local ok, err = ngx.ctx.redis:connect(
        -- Try redis_host or redis_socket, fallback to localhost:6379 (Redis default).
        options.redis.host or options.redis.socket or "127.0.0.1", 
        options.redis.port or 6379
    )
end


function redis_close()
    -- Keep the Redis connection
    ngx.ctx.redis:set_keepalive(
        options.redis.keepalive.max_idle_timeout or 0, 
        options.redis.keepalive.pool_size or 100
    )
end


-- Reads an item from cache
--
-- @param	table   req
-- @param   table   res
-- @return	number  ttl
function read(req, res)
    if not req.accepts_cache() then return nil end

    -- Fetch from Redis, pipeline to reduce overhead
    ngx.ctx.redis:init_pipeline()
    local cache_parts = ngx.ctx.redis:hgetall(ngx.ctx.ledge.cache_key)
    local ttl = ngx.ctx.redis:ttl(ngx.ctx.ledge.cache_key)
    local replies, err = ngx.ctx.redis:commit_pipeline()
    if not replies then
        error("Failed to query redis: " .. err)
    end

    -- A positive TTL tells us if there's anything valid
    local ttl = assert(tonumber(replies[2]), "Bad TTL found for " .. ngx.ctx.ledge.cache_key)
    if ttl <= 0 then return nil end -- Cache miss 

    -- We should get a table of cache entry values
    assert(type(replies[1]) == 'table', "Failed to collect cache data from Redis")

    local cache_parts = replies[1]
    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        if cache_parts[i] == 'body' then
            res.body = cache_parts[i+1]
        elseif cache_parts[i] == 'status' then
            res.status = tonumber(cache_parts[i+1])
        else
            -- Everything else will be a header, with a h: prefix.
            local _, _, header = cache_parts[i]:find('h:(.*)')
            if header then
                res.header[header] = cache_parts[i+1]
            end
        end
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

    -- Check / remove Set-Cookie before saving to cache (See RFC 2109, section 4.2.3).
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("no%-cache=\"set%-cookie\"") ~= nil then
        res.header["Set-Cookie"] = nil
    end

    -- Turn the headers into a flat list of pairs
    local h = {}
    for header,header_value in pairs(res.header) do
        table.insert(h, 'h:'..header)
        table.insert(h, header_value)
    end

    ngx.ctx.redis:init_pipeline()

    ngx.ctx.redis:hmset(ngx.ctx.ledge.cache_key, 
        'body', res.body, 
        'status', res.status,
        'uri', req.uri_full,
        unpack(h)
    )

    -- Set the expiry (this might include an additional stale period)
    ngx.ctx.redis:expire(ngx.ctx.ledge.cache_key, res.ttl())

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    ngx.ctx.redis:zadd('ledge:uris_by_expiry', res.expires_timestamp(), req.uri_full)

    local replies, err = ngx.ctx.redis:commit_pipeline()
    if not replies then
        error("Failed to query Redis: " .. err)
    end
    return assert(replies[1] == "OK" and replies[2] == 1 and type(replies[3]) == 'number', 
        "Unexpeted reply from Redis when trying to save")
end


-- Fetches a resource from the origin server.
--
-- @param	string	The nginx location to proxy using
-- @return	table	Response
function fetch(req, res)
    emit("origin_required", req, res)

    local origin = ngx.location.capture(options.proxy_location..req.uri_relative, {
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
        -- A nice opportunity for post-fetch / pre-save work.
        emit("origin_fetched", req, res)

        -- Save
        assert(save(req, res), "Could not save fetched object")
        return true
    end
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
function fetch_background(req, res)
    ngx.ctx.redis:publish('revalidate', req.uri_full)
end


function set_headers(req, res)
    -- Via header
    local via = '1.1 ' .. req.host .. ' (ledge/' .. _VERSION .. ')'
    if  (res.header['Via'] ~= nil) then
        res.header['Via'] = via .. ', ' .. res.header['Via']
    else
        res.header['Via'] = via
    end

    -- Only add X-Cache headers for cacheable responses
    if res.cacheable() then
        -- Get the cache state as human string for response headers
        local cache_state_human = ''
        for k,v in pairs(cache_states) do
            if v == res.state then
                cache_state_human = tostring(k)
                break
            end
        end
        -- X-Cache header
        if res.state >= cache_states.WARM then
            res.header['X-Cache'] = 'HIT' 
        else
            res.header['X-Cache'] = 'MISS'
        end

        res.header['X-Cache-State'] = cache_state_human
    end
end


-- Set a config parameter
--
-- The vararg is an optional parameter containing a table which specifies per URI or 
-- header based value filters. This allows a config item to only be set on certain URIs, 
-- for example. 
--
-- @param string    The config parameter
-- @param mixed     The config default value
-- @param ...       Filter table. First level is the filter type "match_uri" or "match_header".
--                  Each of these has a list of pattern => value pairs.
function set(param, value, ...)
    if not ngx.ctx.ledge then create_ledge_ctx() end

    ngx.ctx.ledge.config[param] = value
    local filters = select(1, ...)
    if filters then
        if filters.match_uri then
            for _,filter in ipairs(filters.match_uri) do
                if ngx.var.uri:find(filter[1]) ~= nil then
                    ngx.ctx.ledge.config[param] = filter[2]
                    break
                end
            end
        end

        if filters.match_header then
            local h = ngx.req.get_headers()
            for _,filter in ipairs(filters.match_header) do
                if h[filter[1]] ~= nil and h[filter[1]]:find(filter[2]) ~= nil then
                    ngx.ctx.ledge.config[param] = filter[3]
                    break
                end
            end
        end
    end
end


-- Convenience for accessing config parameters
--
-- @param   string  The config parameter
-- @return  mixed
function get(param)
    return ngx.ctx.ledge.config[param] or nil
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
