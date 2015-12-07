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

    local headers = {
        ["Host"] = job.data.host,
        ["Cache-Control"] = "max-stale=0, stale-if-error=0",
    }

    for k, v in pairs(headers) do
        job.data.headers[k] = v
    end

    local res, err = httpc:request{
        method = "GET",
        path = uri,
        headers = job.data.headers
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
