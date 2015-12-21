local http = require "resty.http"
local http_headers = require "resty.http_headers"

local str_match = string.match

local _M = {
    _VERSION = '0.01',
}


function _M.perform(job)
    local httpc = http.new()

    local ok, err = httpc:connect(job.data.server_addr, job.data.server_port)
    if not ok then
        return nil, "job-error", "could not connect to server: " .. err
    end

    if job.data.scheme == "https" then
        local ok, err = httpc:ssl_handshake(false, job.data.host, false)
        if not ok then
            return nil, "job-error", "ssl handshake failed: " .. err
        end
    end

    local headers = http_headers.new()
    headers["Host"] = job.data.headers["host"] -- Always set host from parent
    headers["Cache-Control"] = "max-stale=0, stale-if-error=0"
    headers["User-Agent"] = httpc._USER_AGENT .. " ledge_revalidate/" .. _M._VERSION

    -- Add additional headers from parent
    if job.data.parent_headers then
        for _,hdr in ipairs(job.data.parent_headers) do
            headers[hdr] = job.data.headers[hdr]
        end
    end

    local res, err = httpc:request{
        method = "GET",
        path = job.data.uri,
        headers = headers,
    }

    if not res then
        return nil, "job-error", "revalidate failed: " .. err
    else
        local reader = res.body_reader
        -- Read and discard the body
        repeat
            local chunk, err = reader()
        until not chunk

        httpc:set_keepalive()

        return true, nil, nil
    end
end

return _M
