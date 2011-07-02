module("libledge", package.seeall)

local redis_parser = require("redis.parser") -- https://github.com/agentzh/lua-redis-parser

local ledge = {}


-- Runs a single query and returns the parsed response
--
-- e.g. local res = ledge.redis_query({ 'HGET', 'mykey' })
--
-- @param	table	query expressed as a list of Redis commands
-- @return	mixed	Redis response or false on failure
function ledge.redis_query(query)
	local res = ngx.location.capture(conf.redis.loc, {
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
	
	local rep = ngx.location.capture(conf.redis.loc, {
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
-- @param	string	The URI (cache key)
-- @return	table	The response table
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
		local t = rep[3]
	
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

			return response
		else 
			return false
		end
	else 
		ngx.log(ngx.ERROR, "Failed to read from Redis")
		return false
	end
end


-- Stores an item in cache
--
-- @param	uri			The URI (cache key)
-- @param	response	The HTTP response object to store
--
-- @return boolean
function ledge.save(uri, response)
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
	
	if (res ~= false) then
		ledge.redis_query({ 'PUBLISH', uri.key, 'SAVED' })
	end

end


-- Fetches a resource from the origin server.
--
-- @param	string	The (relative) URI to proxy
-- @return	table	Result table, with .status and .body members
function ledge.fetch_from_origin(uri, in_progress_wait)
	-- See if we're already doing this	
	local r = ledge.redis_query({ 'SISMEMBER', 'proxy', uri.key })
	
	if (r == 0) then -- Nothing happening for this URL
		ngx.log(ngx.NOTICE, "GOING TO ORIGIN")
		
		-- Tell redis we're doing this
		ledge.redis_query({ 'SADD', 'proxy', uri.key })
		
		-- Actually fetch from origin..
		local res = ngx.location.capture(conf.proxy.loc .. uri.uri);

		-- Tell redis we're done (trying or succeeding)
		ledge.redis_pipeline({
			 { 'SREM', 'proxy', uri.key }, 
			 { 'PUBLISH', uri.key, 'FETCHED' }
		})
		
		if (res.status ~= ngx.HTTP_OK) then	
			ngx.log(ngx.ERROR, "Could not fetch " .. uri.uri .. " from the origin")	
		end
		
		return res
	else 	
		-- We are busy doing this already
		
		if (in_progress_wait) then -- If we want to wait..
			
			
			-- Subscribe to channel
			
			-- This isn't going to work.. redis replies straight away and expects you to wait
			-- for messages, but the redis2 module chokes on this reply (it thinks it's bad). Hmmm. 
			-- Not sure what our options are, without having a streamed reply from redis via some
			-- kind of callback...
			
			--[[
			local mq = redis_parser.build_query({
				'SUBSCRIBE', uri.key
			})
			ngx.log(ngx.NOTICE, "Going to wait for redis to say all clear")
			local r = ngx.location.capture(conf.redis.loc, {
				method = ngx.HTTP_POST,
				args = { n = 1 },
				body = mq
			})
			ngx.log(ngx.NOTICE, "Got all clear")
			
			-- We should be in cache now
			--return ledge.read(uri)
			
			]]--
			
			return { status = ngx.HTTP_NOT_FOUND }
			
		else
			return { status = ngx.HTTP_NOT_FOUND } -- For background refresh to not bother saving, no biggie
		end
	end
end


function ledge.refresh(uri)
	local res = ledge.fetch_from_origin(uri)

	-- If res is false, another request is doing this for us
	if res ~= false then
		-- TODO, check if we should still be caching this (policy may have changed)

		-- Save to cache
		if res.status == ngx.HTTP_OK then
			local sres = ledge.save(uri, res)
		end
	end
end


-- TODO: Work out the valid expiry from headers, based on RFC.
function ledge.calculate_expiry(header)
	return 30 + conf.redis.max_stale_age
end


return ledge
