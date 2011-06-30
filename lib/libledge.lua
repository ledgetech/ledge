-- Shared module for handling background refreshes
module("libledge", package.seeall)

local redis_parser = require("redis.parser") -- https://github.com/agentzh/lua-redis-parser
local background_refreshes = {} -- internal, to stop flooding of background refreshes
local ledge = {}


-- Fetches a resource from the origin server
--
-- @param   string	The (relative) URI to proxy
-- @return  table	Result table, with .status and .body members
function ledge.fetch_from_origin(uri)
    local res = ngx.location.capture(conf.proxy.loc .. uri);

    if (res.status == ngx.HTTP_OK) then
        ngx.log(ngx.NOTICE, "Fetched " .. uri .. " from the origin")
    else
        ngx.log(ngx.ERROR, "Could not fetch " .. uri .. " from the origin")
    end

    return res
end


-- Reads an item from cache
--
-- @param	string	The URI (cache key)
-- @return	table	The response table
function ledge.read(uri)
    local header_key = md5.sumhexa(uri)
	
	local q = redis_parser.build_query({
		'HMGET', uri, 'status', 'body'
	})
	
	local header_q = redis_parser.build_query({
		'HGETALL', header_key
	})
	
	local ttl_q = redis_parser.build_query({
		'TTL', uri
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

			ngx.log(ngx.NOTICE, "Cache hit with ttl: " .. response.ttl)

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
-- @param   uri         The URI (cache key)
-- @param   response    The HTTP response object to store
--
-- @return boolean
function ledge.save(uri, response)
    
    local reqs = {}
    local header_key = md5.sumhexa(uri)

    -- Store the response. Header is a foreign key to another hash.
    local q = redis_parser.build_query({ 
        'HMSET', uri, 
        --'body', ngx.encode_base64(response.body), 
		'body', response.body, 
        'status', response.status, 
        'header', header_key
    })
    
    -- Store the headers
    local header_q = { 'HMSET', header_key } 
    for k,v in pairs(response.header) do -- Add each k,v as a pair
        table.insert(header_q, string.lower(k))
        table.insert(header_q, v)
    end
    header_q = redis_parser.build_query(header_q)
    
    -- Work out TTL
    local ttl = ledge.calculate_expiry(response.header)
    local expire_q = redis_parser.build_query({ 'EXPIRE', uri, ttl })
	local expire_hq = redis_parser.build_query({ 'EXPIRE', header_key, ttl })

    -- Send queries to redis all in one go.
    local res = ngx.location.capture(conf.redis.loc, {
        method = ngx.HTTP_POST,
        args = { n = 4 }, -- How many queries
        body = q .. expire_q .. header_q .. expire_hq
    })

    return res
end


function ledge.refresh(uri)
    if (background_refreshes[uri] == nil) then
        background_refreshes[uri] = true
        ngx.log(ngx.NOTICE, "Background refresh...")
        
        -- Re-fetch this resource
        local res = ledge.fetch_from_origin(ngx.var.request_uri)

        -- Save to cache
        if res.status == ngx.HTTP_OK then
           local sres = ledge.save(uri, res)
           if sres.status == ngx.HTTP_OK then
               background_refreshes[uri] = nil
               ngx.log(ngx.NOTICE, "Finished background refresh...")
           end
        end
    end
end


-- TODO: Work out the valid expiry from headers, based on RFC.
function ledge.calculate_expiry(header)
    return 60 + conf.redis.max_stale_age
end


return ledge
