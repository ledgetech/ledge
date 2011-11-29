-- Ledge
--
-- This module does all of the heavy lifting. It is loaded once for the first
-- request. Anything dynamic for your request must be passed to this module (not 
-- stored).
local ledge = {
    version = '0.1-alpha',
    _mt = {},
    
    _config_file = require("config"),
	config = {},
	cache = {},

    redis = require("lib.redis"),

	-- Subrequest locations
	locations = {
		origin = "/__ledge/origin",
		wait_for_origin = "/__ledge/wait_for_origin",
		redis = "/__ledge/redis"
	},

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


-- Specify the metatable.
setmetatable(ledge, ledge._mt)


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


-- Loads runtime configuration into ledge.config
--
-- The configuration file is only loaded once for the first request. 
-- This runs any dynamatic pattern matches for the current request.
--
-- @return void
function ledge.process_config()
	for k,v in pairs(ledge._config_file) do
		-- Grab the default
		ledge.config[k] = ledge._config_file[k].default
		
		-- URI matches
		if ledge._config_file[k].match_uri then
			for i,v in ipairs(ledge._config_file[k].match_uri) do
				if (ngx.var.uri:find(v[1]) ~= nil) then
					ledge.config[k] = v[2]
					break -- We take the first hit
				end
			end
		end
		
		-- Request header matches
		if ledge._config_file[k].match_header then
			local h = ngx.req.get_headers()
			
			for i,v in ipairs(ledge._config_file[k].match_header) do
				if (h[v[1]] ~= nil) and (h[v[1]]:find(v[2]) ~= nil) then
					ledge.config[k] = v[3]
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
function ledge.create_keys(full_uri)
    local keys = {}
    keys.uri = full_uri
    keys.key = 'ledge:'..ngx.md5(full_uri)  -- Hash, with .status, and .body.
    keys.header_key	= keys.key..':header'   -- Hash, with header names and values.
    keys.fetch_key  = keys.key..':fetch'    -- Temp key during collapsed request.
    return keys
end


-- Prepares the response by attempting to read from cache.
-- A skeletol response object will be returned with a state of < WARM
-- in the event of a cache miss.
-- 
-- @param   table   Keys table
-- @return  table   Response object
function ledge.prepare(keys)
    local response = ledge.cache.read(keys)
    if (response) then
        if (response.ttl - ledge.config.max_stale_age <= 0) then
            response.state = ledge.states.WARM
        else
            response.state = ledge.states.HOT
        end
    else
        response = { state = ledge.states.SUBZERO }
    end

    response.keys = keys
    return response
end


-- Sends the response to the client
-- If on_before_send is defined in configuration, the response may be altered
-- by any plugins.
--
-- @param   table   Response object
-- @return  void
function ledge.send(response)
    -- Fire the on_before_send event
    if type(ledge.config.on_before_send) == 'function' then
        response = ledge.config.on_before_send(ledge, response)
    else
        ngx.log(ngx.NOTICE, "on_before_send event handler is not a function")
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
		ngx.header['X-Ledge-Max-Stale-Age'] = ledge.config.max_stale_age
	end
	
	ngx.print(response.body)
	ngx.eof()
end




-- Reads an item from cache
--
-- @param	string			The URI (cache key)
-- @return	bool | table	Success/failure | The response table
function ledge.cache.read(keys)
	-- Fetch from Redis
    local rep = ledge.redis.query_pipeline({
		{ 'HMGET', keys.key, 'status', 'body', 'header' },
		{ 'TTL', keys.key }
	})
	
	if (rep ~= nil) then
		local b = rep[1]
		local t = tonumber(rep[2])
	
		if t > -1 then -- we got something valid and not expired
		    
		    -- Unserialize the headers
			local h = loadstring('return ' .. b[3])

			-- Reassemble a response object
			local response = { -- Main parts will be ordered as per the HMGET args
				status	= b[1],
				body	= b[2],
				ttl		= t,
				header = h(),
			}
			
			return response
		else 
			return nil
		end

	else 
		error("Failed to read from Redis")
		return nil
	end
end


-- Stores an item in cache
--
-- @param	keys		The URI (cache key)
-- @param	response	The HTTP response object to store
-- @return	boolean
function ledge.cache.save(keys, response)
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
		
		local rep = ledge.redis.query_pipeline({ q, expire_q })
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
function ledge.fetch(keys, response)
	if (ledge.config.collapse_origin_requests == false) then
		local origin = ngx.location.capture(ledge.locations.origin..keys.uri, {
            method = ledge.request_method_constant(),
            body = ngx.var.request_body,
        })
		ledge.cache.save(keys, origin)
		
		response.status = origin.status
		response.body = origin.body
		response.header = origin.header
		response.action = ledge.actions.FETCHED
		return response
	else
		-- Set the fetch key
		local fetch = ledge.redis.query({ 'SETNX', keys.fetch_key, '1' })
		-- TODO: Read from config
		ledge.redis.query({ 'EXPIRE', keys.fetch_key, '10' })

		if (fetch == 1) then -- Go do the fetch
			local origin = ngx.location.capture(ledge.locations.origin..keys.uri);
			ledge.cache.save(keys, origin)
			
			-- Remove the fetch and publish to waiting threads
			ledge.redis.query({ 'DEL', keys.fetch_key })
			ledge.redis.query({ 'PUBLISH', keys.key, 'finished' })
			
			response.status = origin.status
			response.body = origin.body
			response.header = origin.header
			response.action = ledge.actions.FETCHED
			return response
		else
			-- This fetch is already happening 
			if (response.state < ledge.states.WARM) then
				-- Go to the collapser proxy
				local rep = ngx.location.capture(ledge.locations.wait_for_origin, {
					args = { channel = keys.key }
				});
			
				if (rep.status == ngx.HTTP_OK) then				
					local results = ledge.redis.parser.parse_replies(rep.body, 2)
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
    --local headers = ngx.req.get_headers()

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
                            + ledge.config.max_stale_age
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


-- Let us know if we're declaring 
getmetatable(ledge).__newindex = function(table, key, val) 
        error(  'Attempt to write to undeclared variable "'..key..'": '
                ..debug.traceback()) 
    end

return ledge
