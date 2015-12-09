local http = require "resty.http"

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

    local request_line = str_match(job.data.raw_header, "[^\r\n]+")
    local uri = str_match(request_line, "[^%s]+%s([^%s]+)")

    if job.data.scheme == "https" then
        local ok, err = httpc:ssl_handshake(false, job.data.host, false)
        if not ok then
            return nil, "job-error", "ssl handshake failed: " .. err
        end
    end

    local res, err = httpc:request{
        method = "GET",
        path = uri,
        headers = {
            ["Host"] = job.data.host,
            ["Cache-Control"] = "max-stale=0, stale-if-error=0",
        },
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
