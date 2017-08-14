local hdr_has_directive = require("ledge.header_util").header_has_directive

local ngx_req_get_headers = ngx.req.get_headers
local ngx_re_gsub = ngx.re.gsub
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_req_get_method = ngx.req.get_method
local ngx_re_find = ngx.re.find

local ngx_var = ngx.var

local tbl_sort = table.sort
local tbl_insert = table.insert


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


local function sort_args(a, b)
    return a[1] < b[1]
end


local function args_sorted(max_args)
    max_args = max_args or 100
    local args = ngx_req_get_uri_args(max_args)
    if not next(args) then return nil end

    local sorted = {}
    for k, v in pairs(args) do
        tbl_insert(sorted, { k, v })
    end

    tbl_sort(sorted, sort_args)

    local sargs = ""
    local sortedln = #sorted
    for i, v in ipairs(sorted) do
        sargs = sargs .. ngx.encode_args({ [v[1]] = v[2] })
        if i < sortedln then sargs = sargs .. "&" end
    end

    return sargs
end
_M.args_sorted = args_sorted


-- Used to generate a default args string for the cache key (i.e. when there are
-- no URI args present).
--
-- Returns a zero length string, unless there is an asterisk at the end of the
-- URI on a PURGE request, in which case we return the asterisk.
--
-- The purpose it to ensure trailing wildcards are greedy across both URI and
-- args portions of a cache key.
--
-- If you override the "args" field in a cache key spec with your own function,
-- you'll want to use this to ensure wildcard purges operate correctly.
local function default_args()
    if ngx_req_get_method() == "PURGE" then
        if ngx_re_find(ngx_var.request_uri, "\\*$", "soj") then
            return "*"
        end
    end
    return ""
end
_M.default_args = default_args


return _M
