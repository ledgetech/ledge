-- ledge
--
-- A Lua implementation of edge proxying logic. Relies heavily on nginx and the excellent
-- tools provided by ngx_openresty (https://github.com/agentzh/ngx_openresty) for embedding
-- lua within nginx, and connecting to Redis as a cache backend, amonst other cool things.
-- 
-- @author James Hurst <jhurst@squiz.co.uk>

conf = require("config")
ledge = require("lib.libledge")
require("md5") -- http://www.keplerproject.org/md5/


-- First, try the cache. Use the full_uri for the cache key (includes scheme/host)
local cache = ledge.read(ngx.var.full_uri)

if cache ~= false then -- Cache HIT, send to client asap     
    for k,v in pairs(cache.header) do
        ngx.header[k] = v
    end
    ngx.header["X-Ledge"] = "Cache HIT"
    ngx.say(cache.body)

    -- Check if we're stale
    if cache.ttl - conf.redis.max_stale_age <= 0 then -- Stale, needs refresh
        ledge.refresh(ngx.var.full_uri)
    end

else
    -- Cache miss.. go fish
    local res = ledge.fetch_from_origin(ngx.var.request_uri)

    if res.status == ngx.HTTP_OK then
        -- Send to browser
        for k,v in pairs(res.header) do
            ngx.header[k] = v
        end
        ngx.header["X-Ledge"] = "Cache MISS, fetched from origin"
        ngx.say(res.body)

        -- TODO: Work out if we're allowed to cache

        -- Save to cache
        ledge.save(ngx.var.full_uri, res)
    else
        -- Nothing in cache and could not proxy for some reason.
        ngx.exit(res.status)
    end
end
