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
    local rep = ngx.location.capture(ngx.var.loc_redis, {
        method = ngx.HTTP_POST,
        args = { n = 1 },
        body = redis.parser.build_query(query)
    })

    if (rep.status == ngx.HTTP_OK) then
        return redis.parser.parse_reply(rep.body)
    else
        return false
    end
end


--
-- Runs multiple queries pipelined. This is faster than parallel subrequests.
--
-- e.g. local reps = redis.query_pipeline({ q1, q2 })
--
-- @param	table	A table of queries, where each query is expressed as a table
-- @return	mixed	A table of parsed replies, or false on failure
-- 
function redis.query_pipeline(queries)
    for i,q in ipairs(queries) do
        queries[i] = redis.parser.build_query(q)
    end

    local rep = ngx.location.capture(ngx.var.loc_redis, {
        args = { n = #queries },
        method = ngx.HTTP_POST,
        body = table.concat(queries)
    })

    local reps = {}

    if (rep.status == ngx.HTTP_OK) then
        local results = redis.parser.parse_replies(rep.body, #queries)
        for i,v in ipairs(results) do
            table.insert(reps, v[1]) -- #1 = res, #2 = typ
        end

        return reps
    else
        return false
    end
end

return redis
