module("ledge.ledge", package.seeall)

_VERSION = '0.01'

-- Perform assertions on the nginx config only on the first run
assert(ngx.var.cache_key, "cache_key not defined in nginx config")
assert(ngx.var.full_uri, "full_uri not defined in nginx config")
assert(ngx.var.relative_uri, "relative_uri not defined in nginx config")
assert(ngx.var.config_file, "config_file not defined in nginx config")

local event = require("ledge.event")
local resty_redis = require("resty.redis")

local redis = resty_redis:new()

local config_file = assert(loadfile(ngx.var.config_file), "Config file not found or will not compile")

local states = {
    SUBZERO = 1,
    COLD    = 2,
    WARM    = 3,
    HOT     = 4,
}

local actions = {
    FETCHED     = 1,
    COLLAPSED   = 2,
}

-- Returns the state name as string (for logging).
-- One of 'SUBZERO', 'COLD', 'WARM', or 'HOT'.
--
-- @param   number  State
-- @return  string  State as a string
function states.tostring(state)
    for k,v in pairs(states) do
        if v == state then
            return k
        end
    end
end


-- Returns the action type as string (for logging).
-- One of 'FETCHED', 'COLLAPSED'.
--
-- @param   number  Action
-- @return  string  Action as a string
function actions.tostring(action)
    for k,v in pairs(actions) do
        if v == action then
            return k
        end
    end
end


-- This is the only public method, to be called from nginx configuration.
--
-- @param   string  The nginx location name for proxying.
-- @return  void
function proxy(proxy_location)
    -- Connect to Redis. Keepalive will stop this from happening on each request.
    -- Try redis_host or redis_socket, fallback to localhost:6379 (Redis default).
    redis:set_timeout(ngx.var.redis_timeout or 1000) -- Default to 1 sec
    local ok, err = redis:connect(
        ngx.var.redis_host or ngx.var.redis_socket or "127.0.0.1", 
        ngx.var.redis_port or 6379
    )

    -- Run the config to determine run level options for this request
    config_file(config)
    event.emit("config_loaded")

    if request_accepts_cache() then
        -- Prepare fetches from cache, so we're either primed with a full response
        -- to send, or cold with an empty response which must be fetched.
        prepare()
        local response = ngx.ctx.response
        -- Send and/or fetch, depending on the state
        if (response.state == states.HOT) then
            send()
        elseif (response.state == states.WARM) then
            background_fetch(proxy_location)
            send()
        elseif (response.state < states.WARM) then
            ngx.ctx.response, status = fetch(proxy_location)
            if not ngx.ctx.response then
                ngx.exit(status)
            end
            send()
        end
    else 
        ngx.ctx.response = { state = states.SUBZERO }
        ngx.ctx.response, status = fetch(proxy_location)
        if not ngx.ctx.response then
            ngx.exit(status)
        end
        send()
    end
    event.emit("finished")

    -- Keep the Redis connection
    redis:set_keepalive(
        ngx.var.redis_keepalive_max_idle_timeout or 0, 
        ngx.var.redis_keepalive_pool_size or 100
    )
end




-- Prepares the response by attempting to read from cache.
-- A skeletol response object will be returned with a state of < WARM
-- in the event of a cache miss.
function prepare()
    local response, state = cache_read()
    if not response then response = {} end -- Cache miss
    response.state = state
    ngx.ctx.response = response
end


-- Reads an item from cache
--
-- @param	string              The URI (cache key)
-- @return	table|nil, state    The response table or nil, the cache state
function cache_read()
    local ctx = ngx.ctx

    -- Fetch from Redis, pipeline to reduce overhead
    redis:init_pipeline()
    local cache_parts = redis:hgetall(ngx.var.cache_key)
    local ttl = redis:ttl(ngx.var.cache_key)
    local replies, err = redis:commit_pipeline()
    if not replies then
        error("Failed to query Redis: " .. err)
    end

    -- Our cache object
    local obj = {
        header = {}
    }
    
    -- A positive TTL tells us if there's anything valid
    obj.ttl = assert(tonumber(replies[2]), "Bad TTL found for " .. ngx.var.cache_key)
    if obj.ttl < 0 then
        return nil, states.SUBZERO  -- Cache miss
    end

    -- We should get a table of cache entry values
    assert(type(replies[1]) == 'table', 
        "Failed to collect cache data from Redis")

    local cache_parts = replies[1]
    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        if cache_parts[i] == 'body' then
            obj.body = cache_parts[i+1]
        elseif cache_parts[i] == 'status' then
            obj.status = cache_parts[i+1]
        else
            -- Everything else will be a header, with a h: prefix.
            local _, _, header = cache_parts[i]:find('h:(.*)')
            if header then
                obj.header[header] = cache_parts[i+1]
            end
        end
    end

    event.emit("cache_accessed")

    -- Determine freshness from config.
    -- TODO: Perhaps we should be storing stale policies rather than asking config?
    if ctx.config.serve_when_stale and obj.ttl - ctx.config.serve_when_stale <= 0 then
        return obj, states.WARM
    else
        return obj, states.HOT
    end
end


-- Stores an item in cache
--
-- @param	response	            The HTTP response object to store
-- @return	boolean|nil, status     Saved state or nil, ngx.capture status on error.
function cache_save(response)
    if not response_is_cacheable(response) then
        return 0 -- Not cacheable, but no error
    end

    redis:init_pipeline()

    -- Turn the headers into a flat list of pairs
    local h = {}
    for header,header_value in pairs(response.header) do
        table.insert(h, 'h:'..header)
        table.insert(h, header_value)
    end

    redis:hmset(ngx.var.cache_key, 
        'body', response.body, 
        'status', response.status,
        'uri', ngx.var.full_uri,
        unpack(h))

    -- Set the expiry (this might include an additional stale period)
    redis:expire(ngx.var.cache_key, calculate_expiry(response))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', response.expires, ngx.var.full_uri)

    local replies, err = redis:commit_pipeline()
    if not replies then
        error("Failed to query Redis: " .. err)
    end
    return assert(replies[1] == "OK" and replies[2] == 1 and type(replies[3]) == 'number')
end


-- Fetches a resource from the origin server.
--
-- @param	string	The nginx location to proxy using
-- @return	table	Response
function fetch(proxy_location)
    event.emit("origin_required")

    local keys = ngx.ctx.keys
    local response = ngx.ctx.response
    local ctx =  ngx.ctx

    -- We must explicitly read the body
    ngx.req.read_body()

    local origin = ngx.location.capture(proxy_location..ngx.var.relative_uri, {
        method = request_method_constant(),
        body = ngx.req.get_body_data(),
    })

    -- Could not proxy for some reason
    if origin.status >= 500 then
        return nil, origin.status
    end 

    ctx.response.status = origin.status
    ctx.response.header = origin.header
    ctx.response.body = origin.body
    ctx.response.action  = actions.FETCHED

    event.emit("origin_fetched")

    -- Save
    assert(cache_save(origin), "Could not save fetched object")

    return ctx.response
end


-- Publish that an item needs fetching in the background.
-- Returns immediately.
function background_fetch()
    redis:publish('revalidate', ngx.var.full_uri)
end


-- Sends the response to the client
-- If on_before_send is defined in configuration, the response may be altered
-- by any plugins.
--
-- @param   table   Response object
-- @return  void
function send()
    local response = ngx.ctx.response
    ngx.status = response.status
    
    -- Update stats
    redis:incr('ledge:counter:' .. states.tostring(response.state):lower())

    -- TODO: Handle Age properly as per http://www.freesoft.org/CIE/RFC/2068/131.htm
    -- Age header
    -- We can't calculate Age without Date, which by default Nginx doesn't proxy.
    -- You must set proxy_pass_header Date; in Nginx for this to work.
    --[[if response.header['Date'] then
        local prev_age = ngx.header['Age'] or 0
        local date = ngx.parse_http_time(response.header['Date'])
    end
    ]]--

    -- Via header
    local via = '1.1 ' .. ngx.var.hostname
    if  (response.header['Via'] ~= nil) then
        ngx.header['Via'] = via .. ', ' .. response.header['Via']
    else
        ngx.header['Via'] = via
    end

    -- Other headers
    for k,v in pairs(response.header) do
        ngx.header[k] = v
    end

    -- X-Cache header
    if response.state >= states.WARM then
        ngx.header['X-Cache'] = 'HIT' 
    else
        ngx.header['X-Cache'] = 'MISS'
    end

    ngx.header['X-Cache-State'] = states.tostring(response.state)
    ngx.header['X-Cache-Action'] = actions.tostring(response.action)
    
    event.emit("response_ready")

    -- Always ensure we send the correct length
    --response.header['Content-Length'] = #response.body
    ngx.print(response.body)

    event.emit("response_sent")

    --ngx.eof()
end


function request_accepts_cache() 
    -- Only cache GET. I guess this should be configurable.
    if request_method_constant() ~= ngx.HTTP_GET then return false end
    local headers = ngx.req.get_headers()
    if headers['cache-control'] == 'no-cache' or headers['Pragma'] == 'no-cache' then
        return false
    end
    return true
end


-- Determines if the response can be stored, based on RFC 2616.
-- This is probably not complete.
function response_is_cacheable(response)
    local cacheable = true

    local nocache_headers = {}
    nocache_headers['Pragma'] = { 'no-cache' }
    nocache_headers['Cache-Control'] = { 
        'no-cache', 
        'must-revalidate', 
        'no-store', 
        'private' 
    }

    for k,v in pairs(nocache_headers) do
        for i,header in ipairs(v) do
            if (response.header[k] and response.header[k] == header) then
                cacheable = false
                break
            end
        end
    end

    return cacheable
end


-- Work out the valid expiry from the Expires header.
function calculate_expiry(response)
    response.ttl = 0
    if (response_is_cacheable(response)) then
        local ex = response.header['Expires']
        if ex then
            local serve_when_stale = ngx.ctx.config.serve_when_stale or 0
            response.expires = ngx.parse_http_time(ex)
            response.ttl =  (response.expires - ngx.time()) + serve_when_stale
        end
    end

    return response.ttl
end


-- Returns the current request method as an ngx.HTTP_{METHOD} constant.
--
-- @param   void
-- @return  const
function request_method_constant()
    local m = ngx.var.request_method
    if (m == "GET") then
        return ngx.HTTP_GET
    elseif (m == "POST") then
        return ngx.HTTP_POST
    elseif (m == "HEAD") then
        return ngx.HTTP_HEAD
    elseif (m == "PUT") then
        return ngx.HTTP_PUT
    elseif (m == "DELETE") then
        return ngx.HTTP_DELETE
    else
        return nil
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
