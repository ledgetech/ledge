local http = require "resty.http"
local http_headers = require "resty.http_headers"
local ngx_null = ngx.null

local _M = {
    _VERSION = "2.0.0",
}


-- Utility to return all items in a Redis hash as a Lua table.
local function hgetall(redis, key)
    local res, err = redis:hgetall(key)
    if not res then
        return nil,
            "could not retrieve " .. tostring(key) .. " data:" .. tostring(err)
    end

    local hash = {}

    local len = #res
    for i = 1, len, 2 do
        hash[res[i]] = res[i + 1]
    end

    return hash
end


function _M.perform(job)
    local redis = job.redis
    local key_chain = job.data.key_chain

    -- Normal background revalidation operates on stored metadata.
    -- A background fetch due to partial content from upstream however, uses the
    -- current request metadata for reval_headers / reval_params and passes it
    -- through as job data.
    local reval_params = job.data.reval_params
    local reval_headers = job.data.reval_headers

    -- If we don't have the metadata in job data, this is a background
    -- revalidation using stored metadata.
    if not reval_params and not reval_headers then
        local err
        reval_params, err = hgetall(redis, key_chain.reval_params)
        if  not reval_params or
            reval_params == ngx_null or
            not reval_params.server_addr then

            return nil, "job-error",
                "Revalidation parameters are missing, presumed evicted. " ..
                tostring(err)
        end

        reval_headers, err = hgetall(redis, key_chain.reval_req_headers)
        if not reval_headers or reval_headers == ngx_null then
            return nil, "job-error",
                 "Revalidation headers are missing, presumed evicted."
        end
    end

    -- Make outbound http request to revalidate
    local httpc = http.new()
    httpc:set_timeouts(
        reval_params.upstream_connect_timeout,
        reval_params.upstream_send_timeout,
        reval_params.upstream_read_timeout
    )

    local port = tonumber(reval_params.server_port)
    local ok, err
    if port then
        ok, err = httpc:connect(reval_params.server_addr, port)
    else
        ok, err = httpc:connect(reval_params.server_addr)
    end

    if not ok then
        return nil, "job-error",
            "could not connect to server: " .. tostring(err)
    end

    if reval_params.scheme == "https" then
        local ok, err = httpc:ssl_handshake(false, nil, false)
        if not ok then
            return nil, "job-error", "ssl handshake failed: " .. tostring(err)
        end
    end

    local headers = http_headers.new() -- Case-insensitive header table
    headers["Cache-Control"] = "max-stale=0, stale-if-error=0"
    headers["User-Agent"] =
        httpc._USER_AGENT .. " ledge_revalidate/" .. _M._VERSION

    -- Add additional headers from parent
    for k,v in pairs(reval_headers) do
        headers[k] = v
    end

    local res, err = httpc:request{
        method = "GET",
        path = reval_params.uri,
        headers = headers,
    }

    if not res then
        return nil, "job-error", "revalidate failed: " .. tostring(err)
    else
        local reader = res.body_reader
        -- Read and discard the body
        repeat
            local chunk, err = reader()
        until not chunk

        httpc:set_keepalive(
            reval_params.keepalive_timeout,
            reval_params.keepalive_poolsize
        )
    end
end


return _M
