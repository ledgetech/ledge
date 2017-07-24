local hdr_has_directive = require("ledge.header_util").header_has_directive

local ngx_req_get_headers = ngx.req.get_headers
local ngx_re_gsub = ngx.re.gsub

local ngx_var = ngx.var


local _M = {
    _VERSION = "1.28.3",
}


local function purge_mode()
    local x_purge = ngx_req_get_headers()["X-Purge"]
    if hdr_has_directive(x_purge, "delete") then
        return "delete"
    elseif hdr_has_directive(x_purge, "revalidate") then
        return "revalidate"
    else
        return "invalidate"
    end
end
_M.purge_mode = purge_mode


local function relative_uri()
    local uri = ngx_re_gsub(ngx_var.uri, "\\s", "%20", "jo") -- encode spaces

    -- encode percentages if an encoded CRLF is in the URI
    -- see: http://resources.infosecinstitute.com/http-response-splitting-attack
    uri = ngx_re_gsub(uri, "%0D%0A", "%250D%250A", "ijo")

    return uri .. ngx_var.is_args .. (ngx_var.query_string or "")
end
_M.relative_uri = relative_uri


local function full_uri()
    return ngx_var.scheme .. '://' .. ngx_var.host .. relative_uri()
end
_M.full_uri = full_uri


local function visible_hostname()
    local name = ngx_var.visible_hostname or ngx_var.hostname
    local server_port = ngx_var.server_port
    if server_port ~= "80" and server_port ~= "443" then
        name = name .. ":" .. server_port
    end
    return name
end
_M.visible_hostname = visible_hostname


local function accepts_cache()
    -- Check for no-cache
    local h = ngx_req_get_headers()
    if hdr_has_directive(h["Pragma"], "no-cache")
       or hdr_has_directive(h["Cache-Control"], "no-cache")
       or hdr_has_directive(h["Cache-Control"], "no-store") then
        return false
    end

    return true
end
_M.accepts_cache = accepts_cache


return _M
