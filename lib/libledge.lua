module("libledge", package.seeall)

local redis_parser = require("redis.parser") -- https://github.com/agentzh/lua-redis-parser

local ledge = {}

require("zmq")
ledge.zmq_ctx = zmq.init(1)

-- Runs a single query and returns the parsed response
--
-- e.g. local res = ledge.redis_query({ 'HGET', 'mykey' })
--
-- @param	table	query expressed as a list of Redis commands
-- @return	mixed	Redis response or false on failure
function ledge.redis_query(query)
	local res = ngx.location.capture(conf.locatons.redis, {
		method = ngx.HTTP_POST,
		args = { n = 1 },
		body = redis_parser.build_query(query)
	})
	
	if (res.status == ngx.HTTP_OK) then
		return redis_parser.parse_reply(res.body)
	else
		return false
	end
end


-- Runs multiple queries pipelined. This is faster than parallel subrequests
-- it seems.
--
-- e.g. local resps = ledge.redis_pipeline({ q1, q2 })
--
-- @param	table	A table of queries, where each query is expressed as a table
-- @return	mixed	An array of parsed replies, or false on failure
function ledge.redis_pipeline(queries)
	for i,q in ipairs(queries) do
		queries[i] = redis_parser.build_query(q)
	end
	
	local rep = ngx.location.capture(conf.locations.redis, {
		args = { n = #queries },
		method = ngx.HTTP_POST,
		body = table.concat(queries)
	})
	
	local reps = {}
	
	if (rep.status == ngx.HTTP_OK) then
		local results = redis_parser.parse_replies(rep.body, #queries)
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
function ledge.read(uri)
	
	-- Fetch from Redis
	local rep = ledge.redis_pipeline({
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
function ledge.save(uri, response)
	-- TODO: Work out if we're allowed to save
	-- We could store headers even if its no-store, so that we know the policy
	-- for this item. Next hit is a cache hit, but reads the headers, and finds 
	-- it has to go fetch anyway (and store, in case the policy changed)
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

	local res = ledge.redis_pipeline({ q, header_q, expire_q, expire_hq })

	-- TODO: Should probably return something.

end


-- Fetches a resource from the origin server.
--
-- @param	string	The (relative) URI to proxy
-- @return	table	Result table, with .status and .body members
function ledge.fetch_from_origin(uri, in_progress_wait)
	-- Increment the subscriber count
	local r = ledge.redis_query({ 'HINCRBY', 'ledge:subscribers', uri.key, "1" })
	
	
	if (r == 1 or in_progress_wait == false) then -- We are the first query for this URI (at least since last expiration)
		
		--  Socket to publish on
		local s = ledge.zmq_ctx:socket(zmq.PUB)
		s:connect("tcp://*:5601")
		
		ngx.log(ngx.NOTICE, "GOING TO ORIGIN")
		
		-- Actually fetch from origin..
		local res = ngx.location.capture(conf.locations.origin .. uri.uri);
		ngx.log(ngx.NOTICE, "FINISHED FROM ORIGIN")

		-- Decrement the count
		local r = ledge.redis_query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
		
		s:send(uri.key .. ':status', zmq.SNDMORE)
		s:send(uri.key .. ' ' .. res.status, zmq.SNDMORE)
		for k,v in pairs(res.header) do
			s:send(uri.key .. ':header', zmq.SNDMORE)
			s:send(uri.key .. ' ' .. k, zmq.SNDMORE)
			s:send(uri.key .. ' ' .. v, zmq.SNDMORE)
		end
		s:send(uri.key .. ':body', zmq.SNDMORE)
		s:send(uri.key .. ' ' .. res.body)
		s:close()
		
		ngx.log(ngx.NOTICE, "PUBLISHED RESULT")
		
		if (res.status ~= ngx.HTTP_OK) then	
			ngx.log(ngx.ERROR, "Could not fetch " .. uri.uri .. " from the origin, got " .. res.status)	
		end
		
		return true, res
	else 	
		-- We are busy doing this already
		ngx.log(ngx.NOTICE, "Wait, there are "..(r-1).." others")
		
		
		if (in_progress_wait) then -- If we want to wait..
			
			
			local res = ngx.location.capture(conf.locations.wait_for_origin .. uri.uri);
	
		
			-- Decrement the counter, even on error
			local r = ledge.redis_query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
			
			if zmq.status == ngx.HTTP_OK then
				return true, zmq
			end
		else
			local r = ledge.redis_query({ 'HINCRBY', 'ledge:subscribers', uri.key, "-1" })
			ngx.log(ngx.NOTICE, "Not waiting as we got it from cache")
			return false, nil -- For background refresh to not bother saving, no biggie
		end
	end
end

-- TODO: Work out the valid expiry from headers, based on RFC.
function ledge.calculate_expiry(header)
	return 15 + conf.redis.max_stale_age
end


return ledge
