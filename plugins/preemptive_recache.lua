local preemptive_recache = {}

function preemptive_recache.go(ledge, response)
    -- Add this response to the sorted set
    if response.ttl ~= nil then
        ledge.redis.query({ 'ZADD', 'ledge:recache', ngx.time() + response.ttl, response.keys.uri })
        
        -- Anything about to die?
        local expiring = ledge.redis.query({ 'ZRANGEBYSCORE', 'ledge:recache', 1, 60 })
        for k,v in pairs(expiring) do
            local keys = ledge.create_keys(v)
            local res = ledge.prepare(keys)
            res = ledge.fetch(keys.uri, res)
        end
    end
end

return preemptive_recache
