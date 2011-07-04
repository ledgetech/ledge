md5 = require("md5")

ledge = require("lib.libledge")
ledge.process_config()

-- A table for uris and keys so we don't have to hash more than once
local uri = {
	uri = ngx.var.full_uri,
	key = 'ledge:'..md5.sumhexa(ngx.var.full_uri)
}
uri['header_key'] = uri.key..':header'

-- TODO:	Handle IMS / Force Refresh by reading request headers. 
--			Assuming standard request for now.

-- First, try the cache. 
local success, cache = ledge.cache.read(uri)

if (success == true) then -- HOT
	ngx.log(ngx.NOTICE, "Cache HIT, with TTL: " .. cache.ttl)
	for k,v in pairs(cache.header) do
		ngx.header[k] = v
	end
	ngx.print(cache.body)
	ngx.log(ngx.NOTICE, "HOT response sent")
	ngx.eof()

	-- Check if we're stale
	if (cache.ttl - ledge.config.max_stale_age <= 0) then -- HOT, BUT STALE
		ngx.log(ngx.NOTICE, "Please refresh")
		local success, res = ledge.fetch_from_origin(uri)
		
		if (success == true) then -- HOT, BUT STALE, BUT NOW REFRESHED
			ledge.cache.save(uri, res)
		end
	end
else
	-- COLD
	ngx.log(ngx.NOTICE, "Cache MISS, go fish...")
	local success, res = ledge.fetch_from_origin(uri, ledge.config.collapse_origin_requests) -- Fetch

	if success == true then
		-- Send to browser
		for k,v in pairs(res.header) do
			ngx.header[k] = v
		end
		ngx.print(res.body)
		ngx.log(ngx.NOTICE, "COLD response sent")
		ngx.eof()

		-- Save to cache
		ledge.cache.save(uri, res)
	else
		ngx.log(ngx.NOTICE, "something went wrong")
		-- Couldn't fetch for some reason
		ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
	end
	
end
