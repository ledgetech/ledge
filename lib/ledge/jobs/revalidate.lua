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

    if job.data.scheme == "https" then
        local ok, err = httpc:ssl_handshake(false, job.data.host, false)
        if not ok then
            return nil, "job-error", "ssl handshake failed: " .. err
        end
    end

    local headers = {
        ["Host"]          = job.data.headers["host"],
        ["Authorization"] = job.data.headers["authorization"],
        ["Cookie"]        = job.data.headers["cookie"],
        ["Cache-Control"] = "max-stale=0, stale-if-error=0",
        ["User-Agent"]    = httpc._USER_AGENT .. " ledge_revalidate/" .. _M._VERSION
    }

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
