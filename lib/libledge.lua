-- Shared module for handling background refreshes
module("libledge", package.seeall)

local redis_parser = require("redis.parser") -- https://github.com/agentzh/lua-redis-parser
local background_refreshes = {} -- internal, to stop flooding of background refreshes
local ledge = {}


--[[
function ledge.redis(parallel, ...)
	if (parallel) then -- Do a capture_multi
		local reqs = {}
		
		for i,v in ipairs(arg) do
			local req = { conf.redis.loc, { 
				args = { n = 1 }, 
				method = ngx.HTTP_POST,
				body = arg}
			table.insert(reqs, req)
		end
		
		local reps = { ngx.location.capture_multi({ reqs })}
		
		local res = {}
		for i,v in ipairs(r) do
			table.insert(res, redis_parser.parser_reply(r.body))
		end
		
		return unpack(res)
	else
		
		-- Do everything in one query
		
		local r = ngx.location.capture({
			
		})
	end
end
]]--


-- Reads an item from cache
--
-- @param	string	The URI (cache key)
-- @return	table	The response table
function ledge.read(uri)
	local q = redis_parser.build_query({
		'HMGET', uri.key, 'status', 'body'
	})
	
	local header_q = redis_parser.build_query({
		'HGETALL', uri.header_key
	})
	
	local ttl_q = redis_parser.build_query({
		'TTL', uri.key
	})
	
	local r, h, t = ngx.location.capture_multi({
		{ conf.redis.loc, { args = { n = 1 }, method = ngx.HTTP_POST, body = q }},
		{ conf.redis.loc, { args = { n = 1 }, method = ngx.HTTP_POST, body = header_q }},
		{ conf.redis.loc, { args = { n = 1 }, method = ngx.HTTP_POST, body = ttl_q }}
	})
	
	if r.status == ngx.HTTP_OK and h.status == ngx.HTTP_OK and t.status == ngx.HTTP_OK then
		r = redis_parser.parse_reply(r.body)
		h = redis_parser.parse_reply(h.body)
		t = redis_parser.parse_reply(t.body)

		if t ~= nil and t > -1 then -- we got something valid
			
			-- Body parts will be as per the HMGET args
			local response = {
				status = r[1],
				--body = ngx.decode_base64(r[2]),
				body = r[2],
				header = {},
				ttl = t,
			}

			-- Whereas header parts will be a flat list of pairs..
			for i=1, #h, 2 do
				response.header[h[i]] = h[i+1]
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
	
	local reqs = {}

	-- Store the response. Header is a foreign key to another hash.
	local q = redis_parser.build_query({ 
		'HMSET', uri.key, 
		--'body', ngx.encode_base64(response.body), 
		'body', response.body, 
		'status', response.status,
		'header', uri.header_key
	})
	
	-- Store the headers
	local header_q = { 'HMSET', uri.header_key } 
	for k,v in pairs(response.header) do -- Add each k,v as a pair
		table.insert(header_q, string.lower(k))
		table.insert(header_q, v)
	end
	header_q = redis_parser.build_query(header_q)
	
	-- Work out TTL
	local ttl = ledge.calculate_expiry(response.header)
	local expire_q = redis_parser.build_query({ 'EXPIRE', uri.key, ttl })
	local expire_hq = redis_parser.build_query({ 'EXPIRE', uri.header_key, ttl })

	-- Send queries to redis all in one go.
	local res = ngx.location.capture(conf.redis.loc, {
		method = ngx.HTTP_POST,
		args = { n = 4 }, -- How many queries
		body = q .. expire_q .. header_q .. expire_hq
	})

	return res
end


-- Fetches a resource from the origin server.
--
-- @param	string	The (relative) URI to proxy
-- @return	table	Result table, with .status and .body members
function ledge.fetch_from_origin(uri, in_progress_wait)
	
	-- See if we're already doing this
	local q = redis_parser.build_query({
		'SISMEMBER', 'proxy', uri.key
	})
	
	local r = ngx.location.capture(conf.redis.loc, {
		method = ngx.HTTP_POST,
		args = { n = 1 },
		body = q
	})
		
	r = redis_parser.parse_reply(r.body)
	
	if (r == 0) then -- Nothing happening for this URL
		ngx.log(ngx.NOTICE, "GOING TO ORIGIN")
		
		-- Tell redis we're doing this
		local q = redis_parser.build_query({
			'SADD', 'proxy', uri.key
		})
		
		local r = ngx.location.capture(conf.redis.loc, {
			method = ngx.HTTP_POST,
			args = { n = 1 },
			body = q
		})
		
		-- Actually fetch from origin..
		local res = ngx.location.capture(conf.proxy.loc .. uri.uri);

		-- Tell redis we're done (trying or succeeding)
		local q = redis_parser.build_query({
			'SREM', 'proxy', uri.key
		})
		
		local mq = redis_parser.build_query({
			'PUBLISH', 'proxy:finished:'..uri.key, '1'
		})
		
		local r = ngx.location.capture(conf.redis.loc, {
			method = ngx.HTTP_POST,
			args = { n = 2 },
			body = q .. mq
		})
		
		if (res.status ~= ngx.HTTP_OK) then	
			ngx.log(ngx.ERROR, "Could not fetch " .. uri.uri .. " from the origin")	
		end
		
		return res
	else 	
		
		-- We are busy doing this already
		
		if (in_progress_wait) then
			
			
			-- Subscribe to channel
			
			-- This isn't going to work.. redis replies straight away and expects you to wait
			-- for messages, but the redis2 module chokes on this. Hmmm. 
			-- Not sure what our options are, without having a streamed reply from redis.
			
			--[[
			local mq = redis_parser.build_query({
				'SUBSCRIBE', 'proxy:finished:'..uri.key
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
			return { status = ngx.HTTP_NOT_FOUND }
		end
	end
end


function ledge.refresh(uri)	
	-- Re-fetch this resource
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
