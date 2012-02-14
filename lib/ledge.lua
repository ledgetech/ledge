local redis = require("lib.redis")

local ledge = {
    version = '0.1',

    _config_file = require("config"),
    cache = {}, -- Namespace

    states = {
        SUBZERO		= 1,
        COLD		= 2,
        WARM		= 3,
        HOT			= 4,
    },

    actions = {
        FETCHED		= 1,
        COLLAPSED	= 2,
        ABSTAINED	= 3,
    },
}


function ledge.main()
    -- Read in the config file to determine run level options for this request
    ledge.process_config()
    ledge.create_keys()

    if ledge.request_is_cacheable() then
        -- Prepare fetches from cache, so we're either primed with a full response
        -- to send, or cold with an empty response which must be fetched.
        ledge.prepare()

        local response = ngx.ctx.response
        -- Send and/or fetch, depending on the state
        if (response.state == ledge.states.HOT) then
            ledge.send()
        elseif (response.state == ledge.states.WARM) then
            ledge.send()
            ledge.fetch()
        elseif (response.state < ledge.states.WARM) then
            ngx.ctx.response = ledge.fetch()
            ledge.send()
        end
    else 
        ngx.ctx.response = { state = ledge.states.SUBZERO }
        ngx.ctx.response = ledge.fetch()
        ledge.send()
    end
end


-- Returns the current request method as an ngx.HTTP_{METHOD} constant.
--
-- @param   void
-- @return  const
function ledge.request_method_constant()
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


-- Returns the state name as string (for logging).
-- One of 'SUBZERO', 'COLD', 'WARM', or 'HOT'.
--
-- @param   number  State
-- @return  string  State as a string
function ledge.states.tostring(state)
    for k,v in pairs(ledge.states) do
        if v == state then
            return k
        end
    end
end


-- Returns the action type as string (for logging).
-- One of 'FETCHED', 'COLLAPSED', or 'ABSTAINED'.
--
-- @param   number  Action
-- @return  string  Action as a string
function ledge.actions.tostring(action)
    for k,v in pairs(ledge.actions) do
        if v == action then
            return k
        end
    end
end


-- Loads runtime configuration into ngx.ctx.config
--
-- The configuration file is only loaded once for the first request. 
-- This runs any dynamatic pattern matches for the current request.
--
-- @return void
function ledge.process_config()
    if ngx.ctx.config == nil then 
        ngx.ctx.config = {} 
    end

    for k,v in pairs(ledge._config_file) do
        -- Grab the default
        ngx.ctx.config[k] = ledge._config_file[k].default

        -- URI matches
        if ledge._config_file[k].match_uri then
            for i,v in ipairs(ledge._config_file[k].match_uri) do
                if (ngx.var.uri:find(v[1]) ~= nil) then
                    ngx.ctx.config[k] = v[2]
                    break -- We take the first hit
                end
            end
        end

        -- Request header matches
        if ledge._config_file[k].match_header then
            local h = ngx.req.get_headers()

            for i,v in ipairs(ledge._config_file[k].match_header) do
                if (h[v[1]] ~= nil) and (h[v[1]]:find(v[2]) ~= nil) then
                    ngx.ctx.config[k] = v[3]
                    break
                end
            end
        end
    end
end


-- Creates and returns a table of cache keys for the URI
--
-- @param   string  Full URI
-- @return  table   Keys table
function ledge.create_keys()
    local keys = {}
    keys.uri = ngx.var.full_uri
    keys.key = 'ledge:'..ngx.md5(keys.uri)  -- Hash, with .status, and .body.
    keys.header_key	= keys.key..':header'   -- Hash, with header names and values.
    keys.fetch_key  = keys.key..':fetch'    -- Temp key during collapsed request.
    ngx.ctx.keys = keys
end


-- Prepares the response by attempting to read from cache.
-- A skeletol response object will be returned with a state of < WARM
-- in the event of a cache miss.
-- 
-- @param   table   Keys table
-- @return  table   Response object
function ledge.prepare()
    local response, state = ledge.cache.read(ngx.ctx.keys)
    if not response then response = {} end -- Cache miss
    response.state = state
    response.keys = ngx.ctx.keys
    ngx.ctx.response = response
end


-- Sends the response to the client
-- If on_before_send is defined in configuration, the response may be altered
-- by any plugins.
--
-- @param   table   Response object
-- @return  void
function ledge.send()
    local response = ngx.ctx.response

    -- Fire the on_before_send event
    if type(ngx.ctx.config.on_before_send) == 'function' then
        response = ngx.ctx.config.on_before_send(ledge, response)
    else
        --ngx.log(ngx.NOTICE, "on_before_send event handler is not a function")
    end

    ngx.status = response.status

    -- Via header
    local via = '1.1 ' .. ngx.var.hostname .. ' (Ledge/' .. ledge.version .. ')'
    if  (response.header['Via'] ~= nil) then
        ngx.header['Via'] = via .. ', ' .. response.header['Via']
    else
        ngx.header['Via'] = via
    end

    -- Other headers
    for k,v in pairs(response.header) do
        ngx.header[k] = v
    end

    -- Set the X-Ledge headers (these may change)
    ngx.header['X-Ledge-State'] = ledge.states.tostring(response.state)
    if response.action then
        ngx.header['X-Ledge-Action'] = ledge.actions.tostring(response.action)
    end
    if response.ttl then
        ngx.header['X-Ledge-TTL'] = response.ttl
        ngx.header['X-Ledge-Max-Stale-Age'] = ngx.ctx.config.max_stale_age
    end

    ngx.print(response.body)
    ngx.eof()
end


-- Reads an item from cache
--
-- @param	string			The URI (cache key)
-- @return	bool | table	Success/failure | The response table
function ledge.cache.read()
    local ctx = ngx.ctx

    -- Fetch from Redis
    local reply = assert(redis.query_pipeline({
        { 'HMGET', ctx.keys.key, 'status', 'body', 'header' },
        { 'TTL', ctx.keys.key }
    }), "Failed to read from Redis")

    local obj = {}
    
    -- A positive TTL tells us if there's anything valid
    obj.ttl = assert(tonumber(reply[2]), "Bad TTL found for " .. ctx.keys.key)
    if obj.ttl < 0 then
        return nil, ledge.states.SUBZERO  -- Cache miss
    end

    -- Bail if the cache entry looks bad in any way
    obj.status  = assert(reply[1][1], "No status found for " .. ctx.keys.key)
    obj.body    = assert(reply[1][2], "No body found for " .. ctx.keys.key)
    obj.header  = assert(reply[1][3], "No headers found for " .. ctx.keys.key)
    obj.header  = assert(loadstring('return ' .. obj.header)(), 
                    "Count not unserialize headers for " .. ctx.keys.key)

    -- Determine freshness from config.
    -- TODO: Perhaps we should be storing stale policies rather than asking config?
    if obj.ttl - ctx.config.max_stale_age <= 0 then
        return obj, ledge.states.WARM
    else
        return obj, ledge.states.HOT
    end
end


-- Stores an item in cache
--
-- @param	response	The HTTP response object to store
-- @return	boolean
function ledge.cache.save(response)
    local keys = ngx.ctx.keys

    if  (ngx.var.request_method == "GET") and 
        (ledge.response_is_cacheable(response)) then

        -- Store the headers serialized
        local header_s = ledge.serialize(response.header)

        -- Store the response.
        local q = { 
            'HMSET', keys.key, 
            'body', response.body, 
            'status', response.status,
            'header', header_s
        }

        -- Work out TTL
        local ttl = ledge.calculate_expiry(response)
        local expire_q = { 'EXPIRE', keys.key, ttl }

        local rep = redis.query_pipeline({ q, expire_q })
        -- TODO: Check for success

        return true
    else
        return nil
    end
end


-- Fetches a resource from the origin server.
--
-- @param	table	The URI table
-- @return	table	Response
function ledge.fetch()
    local keys = ngx.ctx.keys
    local response = ngx.ctx.response
    if (ngx.ctx.config.collapse_origin_requests == false) then
        local uri = ngx.var.uri
        if ngx.var.args ~= nil then
            uri = uri .. '?' .. ngx.var.args
        end
        local origin = ngx.location.capture(ngx.var.loc_origin..uri, {
            method = ledge.request_method_constant(),
            body = ngx.var.request_body,
        })
        ledge.cache.save(origin)

        response.status = origin.status
        response.body = origin.body
        response.header = origin.header
        response.action = ledge.actions.FETCHED
        return response
    else
        -- Set the fetch key
        local fetch = redis.query({ 'SETNX', keys.fetch_key, '1' })
        -- TODO: Read from config
        redis.query({ 'EXPIRE', keys.fetch_key, '10' })

        if (fetch == 1) then -- Go do the fetch
            local origin = ngx.location.capture(ngx.var.loc_origin..keys.uri);
            ledge.cache.save(origin)

            -- Remove the fetch and publish to waiting threads
            redis.query({ 'DEL', keys.fetch_key })
            redis.query({ 'PUBLISH', keys.key, 'finished' })

            response.status = origin.status
            response.body = origin.body
            response.header = origin.header
            response.action = ledge.actions.FETCHED
            return response
        else
            -- This fetch is already happening 
            if (response.state < ledge.states.WARM) then
                -- Go to the collapser proxy
                local rep = ngx.location.capture(ngx.var.loc_wait_for_origin, {
                    args = { channel = keys.key }
                });

                if (rep.status == ngx.HTTP_OK) then				
                    local results = redis.parser.parse_replies(rep.body, 2)
                    local messages = results[2][1] -- Second reply, body

                    for k,v in pairs(messages) do
                        if (v == 'finished') then

                            ngx.log(ngx.NOTICE, "FINISHED WAITING")

                            -- Go get from redis
                            local cache = ledge.cache.read(keys)
                            response.status = cache.status
                            response.body = cache.body
                            response.header = cache.header
                            response.action = ledge.actions.COLLAPSED
                            return response

                        end
                    end
                else
                    return nil, rep.status -- Pass on the failure
                end
            else -- Is WARM and already happening, so bail
                response.action = ledge.actions.ABSTAINED
                return response
            end
        end
    end
end


function ledge.request_is_cacheable() 
    local headers = ngx.req.get_headers()
    if headers['Cache-Control'] == 'no-cache' or headers['Pragma'] == 'no-cache' then
        return false
    end
    return true
end


-- Determines if the response can be stored, based on RFC 2616.
-- This is probably not complete.
function ledge.response_is_cacheable(response)
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
function ledge.calculate_expiry(response)
    response.ttl = 0
    if (ledge.response_is_cacheable(response)) then
        local ex = response.header['Expires']
        if ex then
            response.ttl =  (ngx.parse_http_time(ex) - ngx.time()) 
            + ngx.ctx.config.max_stale_age
        end
    end

    return response.ttl
end


-- Utility to serialize data
--
-- @param   mixed   Data to serialize
-- @return  string
function ledge.serialize(o)
    if type(o) == "number" then
        return o
    elseif type(o) == "string" then
        return string.format("%q", o)
    elseif type(o) == "table" then
        local t = {}
        table.insert(t, "{\n")
        for k,v in pairs(o) do
            table.insert(t, "  [")
            table.insert(t, ledge.serialize(k))
            table.insert(t, "] = ")
            table.insert(t, ledge.serialize(v))
            table.insert(t, ",\n")
        end
        table.insert(t, "}\n")
        return table.concat(t)
    else
        error("cannot serialize a " .. type(o))
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


return ledge
