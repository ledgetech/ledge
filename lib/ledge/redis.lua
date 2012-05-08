local redis = {
    parser = require("redis.parser"),
}


-- Runs a single query and returns the parsed response
--
-- e.g. local rep = redis.query({ 'HGET', 'mykey' })
--
-- @param	table	query expressed as a list of Redis commands
-- @return	mixed	Redis response or false on failure
function redis.query(query)
    local res = ngx.location.capture(ngx.var.loc_redis, {
        method = ngx.HTTP_POST,
        args = { n = 1 },
        body = redis.parser.build_query(query)
    })

    if (res.status == ngx.HTTP_OK) then
        return redis.parser.parse_reply(res.body)
    else
        return nil, res.status
    end
end


-- Runs multiple queries pipelined. This is faster than parallel subrequests.
--
-- e.g. local reps = redis.query_pipeline({ q1, q2 })
--
-- @param	table	A table of queries, where each query is expressed as a table
-- @return	mixed	A table of parsed replies, or false on failure
function redis.query_pipeline(queries)
    for i,q in ipairs(queries) do
        queries[i] = redis.parser.build_query(q)
    end

    local res = ngx.location.capture(ngx.var.loc_redis, {
        args = { n = #queries },
        method = ngx.HTTP_POST,
        body = table.concat(queries)
    })

    if (res.status == ngx.HTTP_OK) then
        local reps = {}
        local results = redis.parser.parse_replies(res.body, #queries)
        for _,v in ipairs(results) do
            table.insert(reps, v[1]) -- #1 = res, #2 = typ
        end

        return reps
    else
        return nil, res.status
    end
end


-- Metatable
--
-- To avoid race conditions, we specify a shared metatable and detect any 
-- attempt to accidentally declare a field in this module from outside.
setmetatable(redis, {})
getmetatable(redis).__newindex = function(table, key, val) 
    error('Attempt to write to undeclared variable "'..key..'": '..debug.traceback()) 
end


return redis
