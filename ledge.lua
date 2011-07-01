-- ledge
--
-- A Lua implementation of edge proxying logic. Relies heavily on nginx and the excellent
-- tools provided by ngx_openresty (https://github.com/agentzh/ngx_openresty) for embedding
-- lua within nginx, and connecting to Redis as a cache backend, amonst other cool things.
-- 
-- @author James Hurst <jhurst@pintsized.co.uk>

md5 = require("md5")
conf = require("config")
ledge = require("lib.libledge")

-- A table for uris and keys so we don't have to hash more than once
local uri = {
	uri = ngx.var.full_uri,
	key = 'cache:'..md5.sumhexa(ngx.var.full_uri)
}
uri['header_key'] = uri.key..':header'


-- First, try the cache. Use the full_uri for the cache key (includes scheme/host)
local cache = ledge.read(uri)

if cache ~= false then -- Cache HIT, send to client asap
	ngx.log(ngx.NOTICE, "Cache HIT, with TTL: " .. cache.ttl)
	for k,v in pairs(cache.header) do
		ngx.header[k] = v
	end
	ngx.header["X-Ledge"] = "Cache HIT"
	ngx.print(cache.body)
	ngx.eof()

	-- Check if we're stale
	if cache.ttl - conf.redis.max_stale_age <= 0 then -- Stale, needs refresh
		ngx.log(ngx.NOTICE, "Please refresh")
		ledge.refresh(uri)
	end

else
	-- Cache miss.. go fish
	ngx.log(ngx.NOTICE, "Cache MISS, go fish...")
	local res = ledge.fetch_from_origin(uri, true)

	if res.status == ngx.HTTP_OK then
		-- Send to browser
		for k,v in pairs(res.header) do
			ngx.header[k] = v
		end
		ngx.header["X-Ledge"] = "Cache MISS, fetched from origin"
		ngx.print(res.body)
		ngx.eof()

		-- TODO: Work out if we're allowed to cache

		-- Save to cache
		ledge.save(uri, res)
	else
		-- Nothing in cache and could not proxy for some reason.
		ngx.exit(res.status)
	end
end
