local preemptive_recache = {}

function preemptive_recache.go(ledge, response)
    -- Add this response to the sorted set
    if response.ttl ~= nil then
        ledge.redis.query({ 'ZADD', 'ledge:recache', response.ttl, response.uri.uri })
        
        -- Anything about to die?
        local expiring = ledge.redis.query({ 'ZRANGEBYSCORE', 'ledge:recache', 1, 60 })
        for k,v in pairs(expiring) do
            local uri = {}
            uri.uri 		= v
            uri.key 		= 'ledge:'..ngx.md5(v) -- Hash, with .status, and .body
            uri.header_key	= uri.key..':header'	-- Hash, with header names and values
            uri.meta_key	= uri.key..':meta'		-- Meta, hash with .cacheable = true|false. Persistent.
            uri.fetch_key	= uri.key..':fetch'		-- Temp key during an origin request.
            local res = ledge.prepare(uri)
            local res = ledge.fetch(v, res)
        end
    end
end

return preemptive_recache
