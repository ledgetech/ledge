local http = require "resty.http"

local _M = {
    _VERSION = '0.01',
}


function _M.perform(job)
    local httpc = http.new()

    local ok, err = httpc:connect(job.data.server_addr, job.data.server_port)
    if not ok then
        ngx.log(ngx.DEBUG, err)
        return nil, "job-error", "could not connect to server: " .. err
    end

    ngx.log(ngx.DEBUG, job.data.raw_header)

    local request_line = string.match(job.data.raw_header, "[^\r\n]+")
    local uri = string.match(request_line, "[^%s]+%s([^%s]+)")

    local res, err = httpc:request{
        method = "GET",
        path = uri,
        headers = {
            ["Host"] = job.data.host,
            ["Cache-Control"] = "max-stale=0",
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
