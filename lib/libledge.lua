module("libledge", package.seeall)


-- Ledge
--
-- This module is loaded once for the first request, and so 
local ledge = {
	_config_file = require("config"),
	config = {},
	redis = {
		parser = require("redis.parser"),
	},
	cache = {},
	zmq = require("zmq").init(1),
	locations = {
		origin = "/__ledge/origin",
		wait_for_origin = "/__ledge/wait_for_origin",
		redis = "/__ledge/redis"
	}
}


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

	ngx.log(ngx.NOTICE, "ledge.config.max_stale_age: " .. tostring(ledge.config.max_stale_age))
	ngx.log(ngx.NOTICE, "ledge.config.collapse_origin_requests: " .. tostring(ledge.config.collapse_origin_requests))
	ngx.log(ngx.NOTICE, "ledge.config.process_esi: " .. tostring(ledge.config.process_esi))
end


-- Runs a single query and returns the parsed response
--
-- e.g. local res = ledge.redis.query({ 'HGET', 'mykey' })
--
-- @param	table	query expressed as a list of Redis commands
-- @return	mixed	Redis response or false on failure
function ledge.redis.query(query)
	local res = ngx.location.capture(ledge.locations.redis, {
		method = ngx.HTTP_POST,
		args = { n = 1 },
		body = ledge.redis.parser.build_query(query)
	})
	
	if (res.status == ngx.HTTP_OK) then
		return ledge.redis.parser.parse_reply(res.body)
	else
		return false
	end
end


-- Runs multiple queries pipelined. This is faster than parallel subrequests
-- it seems.
--
-- e.g. local resps = ledge.redis.query_pipeline({ q1, q2 })
--
-- @param	table	A table of queries, where each query is expressed as a table
-- @return	mixed	An array of parsed replies, or false on failure
function ledge.redis.query_pipeline(queries)
	for i,q in ipairs(queries) do
		queries[i] = ledge.redis.parser.build_query(q)
	end
	
	local rep = ngx.location.capture(ledge.locations.redis, {
		args = { n = #queries },
		method = ngx.HTTP_POST,
		body = table.concat(queries)
	})
	
	local reps = {}
	
	if (rep.status == ngx.HTTP_OK) then
		local results = ledge.redis.parser.parse_replies(rep.body, #queries)
		for i,v in ipairs(results) do
			table.insert(reps, v[1]) -- #1 = res, #2 = typ
		end
		return reps
	else
		return false
	end
end


-- Reads an item from cache
--
-- @param	string			The URI (cache key)
-- @return	bool | table	Success/failure | The response table
function ledge.cache.read(uri)
	
	-- Fetch from Redis
	local rep = ledge.redis.query_pipeline({
		{ 'HMGET', uri.key, 'status', 'body' },	-- Main content
		{ 'HGETALL', uri.header_key }, 			-- Headers
		{ 'TTL', uri.key }						-- TTL
	})
	
	if (r ~= false) then
		local b = rep[1]
		local h = rep[2]
		local t = tonumber(rep[3])
	
		if t > -1 then -- we got something valid
			
			-- Reassemble a response object
			local response = { -- Main parts will be ordered as per the HMGET args
				status = b[1],
				body = b[2],
				header = {},
				ttl = t,
			}

			-- Whereas header parts will be a flat list of pairs..
			for i = 1, #h, 2 do
				response.header[h[i]] = h[i + 1]
			end

			return true, response
		else 
			return false, nil
		end
	else 
		ngx.log(ngx.ERROR, "Failed to read from Redis")
		return false, nil
	end
end


-- Stores an item in cache
--
-- @param	uri			The URI (cache key)
-- @param	response	The HTTP response object to store
--
-- @return boolean
function ledge.cache.save(uri, response)
	-- TODO: Work out if we're allowed to save
	-- We could store headers even if its no-store, so that we know the policy
	-- for this item. Next hit is a cache hit, but reads the headers, and finds 
	-- it has to go fetch anyway (and store, in case the policy changed)
	--
	-- This might allow for collapse forwaring to be on, but only used by known cacheable content?
	--
	-- On first request (so we know nothing), concurrent requests get told to wait, 
	-- as if they will get the shared hit, and if it's no-store, told
	-- to fetch in the end. But that will only happen once per URI. Potential flood I guess.
	
	-- Store the response. Header is a foreign key to another hash.
	local q = { 
		'HMSET', uri.key, 
		'body', response.body, 
		'status', response.status,
		'header', uri.header_key
	}
	
	-- Store the headers
	local header_q = { 'HMSET', uri.header_key } 
	for k,v in pairs(response.header) do -- Add each k,v as a pair
		table.insert(header_q, string.lower(k))
		table.insert(header_q, v)
	end
	
	-- Work out TTL
	local ttl = ledge.calculate_expiry(response.header)
	local expire_q = { 'EXPIRE', uri.key, ttl }
	local expire_hq = { 'EXPIRE', uri.header_key, ttl }

	local res = ledge.redis.query_pipeline({ q, header_q, expire_q, expire_hq })

	-- TODO: Should probably return something.

end


-- Fetches a resource from the origin server.
--
-- @param	string	The (relative) URI to proxy
-- @return	table	Result table, with .status and .body members
function ledge.fetch_from_origin(uri, collapse_forwarding)
	
	-- Increment the subscriber count
	local r = ledge.redis.query({ 'HINCRBY', 'ledge:subscribers', uri.key, "1" })
	
	if (r == 1) then -- We are the first query for this URI (at least since last expiration)
		
		--  Socket to publish on
		local s = ledge.zmq:socket(zmq.PUB)
		s:bind("tcp://*:5601")
		
		ngx.log(ngx.NOTICE, "GOING TO ORIGIN")
		
		-- Actually fetch from origin..
		local res = ngx.location.capture(ledge.locations.origin .. uri.uri);
		ngx.log(ngx.NOTICE, "FINISHED FROM ORIGIN")

		-- Decrement the count
		local r = ledge.redis.query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
		
		-- Publish to subscribers (collapsed requests)
		s:send(uri.key .. ':status', zmq.SNDMORE)
		s:send(uri.key .. ' ' .. res.status, zmq.SNDMORE)
		for k,v in pairs(res.header) do
			s:send(uri.key .. ':header', zmq.SNDMORE)
			s:send(uri.key .. ' ' .. k, zmq.SNDMORE)
			s:send(uri.key .. ' ' .. v, zmq.SNDMORE)
		end
		s:send(uri.key .. ':body', zmq.SNDMORE)
		s:send(uri.key .. ' ' .. res.body, zmq.SNDMORE)
		s:send(uri.key .. ':end')
		s:close()
		
		ngx.log(ngx.NOTICE, "PUBLISHED RESULT")
		
		return true, res
	else 	
		-- COLD but we are busy doing this already
		if (collapse_forwarding == true) then -- If we want to wait..
			
			ngx.log(ngx.NOTICE, "WAIT FOR ORIGIN")
			
			-- Decrement the counter, even on error
			local r = ledge.redis.query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
			
			-- Go to the collapser proxy
			local res = ngx.location.capture(ledge.locations.wait_for_origin .. uri.uri, {
				args = { channel = uri.key }
			});
			
			ngx.log(ngx.NOTICE, "WAIT STATUS: " .. res.status)
			
			if (res.status >= 500) then
				ngx.log(ngx.NOTICE, "COLLAPSE FAILED")
				return false, res
				
				--[[
				ngx.log(ngx.NOTICE, "GOING TO ORIGIN")

				-- Actually fetch from origin..
				res = ngx.location.capture(ledge.locations.origin .. uri.uri);
				ngx.log(ngx.NOTICE, "FINISHED FROM ORIGIN")
				--]]
			else
			
				ngx.log(ngx.NOTICE, "FINISHED WAITING")
			end
	
			
			return true, res
		else
			-- HOT and STALE, but we're already doing it
			local r = ledge.redis.query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
			ngx.log(ngx.NOTICE, "In progress, but I'm not waiting")
			return false, nil -- For background refresh to not bother saving, no biggie
		end
	end
end

-- TODO: Work out the valid expiry from headers, based on RFC.
function ledge.calculate_expiry(header)
	return 60 + ledge.config.max_stale_age
end

return ledge
