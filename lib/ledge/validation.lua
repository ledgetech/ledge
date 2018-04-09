local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_set_header = ngx.req.set_header
local ngx_parse_http_time = ngx.parse_http_time

local get_numeric_header_token =
    require("ledge.header_util").get_numeric_header_token
local header_has_directive = require("ledge.header_util").header_has_directive


local _M = {
    _VERSION = "2.1.1",
}


-- True if the request or response (res) demand revalidation.
local function must_revalidate(res)
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_max_age = get_numeric_header_token(req_cc, "max-age")
    if req_cc_max_age == 0 then
        return true
    else
        local res_age = tonumber(res.header["Age"])
        local res_cc = res.header["Cache-Control"]

        if header_has_directive(res_cc, "(must|proxy)-revalidate") then
            return true
        elseif req_cc_max_age and res_age then
            if req_cc_max_age < res_age then
                return true
            end
        end
    end
    return false
end
_M.must_revalidate = must_revalidate


-- True if the request contains valid conditional headers.
local function can_revalidate_locally()
    local req_h = ngx_req_get_headers()
    local req_ims = req_h["If-Modified-Since"]

    if req_ims then
        if not ngx_parse_http_time(req_ims) then
            -- Bad IMS HTTP datestamp, lets remove this.
            ngx_req_set_header("If-Modified-Since", nil)
        else
            return true
        end
    end

    if req_h["If-None-Match"] and req_h["If-None-Match"] ~= "" then
        return true
    end

    return false
end
_M.can_revalidate_locally = can_revalidate_locally


-- True if the request conditions indicate that the response (res) can be served
local function is_valid_locally(res)
    local req_h = ngx_req_get_headers()

    local res_lm = res.header["Last-Modified"]
    local req_ims = req_h["If-Modified-Since"]

    if res_lm and req_ims then
        local res_lm_parsed = ngx_parse_http_time(res_lm)
        local req_ims_parsed = ngx_parse_http_time(req_ims)

        if res_lm_parsed and req_ims_parsed then
            if res_lm_parsed <= req_ims_parsed then
                return true
            end
        end
    end

    local res_etag = res.header["Etag"]
    local req_inm = req_h["If-None-Match"]
    if res_etag and req_inm and res_etag == req_inm then
        return true
    end

    return false
end
_M.is_valid_locally = is_valid_locally


return _M
