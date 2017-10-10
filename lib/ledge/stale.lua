local math_min = math.min

local ngx_req_get_headers = ngx.req.get_headers

local header_has_directive = require("ledge.header_util").header_has_directive
local get_numeric_header_token =
    require("ledge.header_util").get_numeric_header_token


local _M = {
    _VERSION = "2.0.4"
}


-- True if the request specifically asks for stale (req.cc.max-stale) and the
-- response doesn't explicitly forbid this res.cc.(must|proxy)-revalidate.
local function can_serve_stale(res)
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_max_stale = get_numeric_header_token(req_cc, "max-stale")
    if req_cc_max_stale then
        local res_cc = res.header["Cache-Control"]

        -- Check the response permits this at all
        if header_has_directive(res_cc, "(must|proxy)-revalidate") then
            return false
        else
            if (req_cc_max_stale * -1) <= res.remaining_ttl then
                return true
            end
        end
    end
    return false
end
_M.can_serve_stale = can_serve_stale


-- Returns true if stale-while-revalidate or stale-if-error is specified, valid
-- and not constrained by other factors such as max-stale.
-- @param   token  "stale-while-revalidate" | "stale-if-error"
local function verify_stale_conditions(res, token)
    assert(token == "stale-while-revalidate" or token == "stale-if-error",
        "unknown token: " .. tostring(token))

    local res_cc = res.header["Cache-Control"]
    local res_cc_stale = get_numeric_header_token(res_cc, token)

    -- Check the response permits this at all
    if header_has_directive(res_cc, "(must|proxy)-revalidate") then
        return false
    end

    -- Get request header tokens
    local req_cc = ngx_req_get_headers()["Cache-Control"]
    local req_cc_stale = get_numeric_header_token(req_cc, token)
    local req_cc_max_age = get_numeric_header_token(req_cc, "max-age")
    local req_cc_max_stale = get_numeric_header_token(req_cc, "max-stale")

    local stale_ttl = 0
    -- If we have both req and res stale-" .. reason, use the lower value
    if req_cc_stale and res_cc_stale then
        stale_ttl = math_min(req_cc_stale, res_cc_stale)
    -- Otherwise return the req or res value
    elseif req_cc_stale then
        stale_ttl = req_cc_stale
    elseif res_cc_stale then
        stale_ttl = res_cc_stale
    end

    if stale_ttl <= 0 then
        return false -- No stale policy defined
    elseif header_has_directive(req_cc, "min-fresh") then
        return false -- Cannot serve stale as request demands freshness
    elseif req_cc_max_age and
        req_cc_max_age < (tonumber(res.header["Age"] or 0) or 0) then
        return false -- Cannot serve stale as req max-age is less than res Age
    elseif req_cc_max_stale and req_cc_max_stale < stale_ttl then
        return false -- Cannot serve stale as req max-stale is less than S-W-R
    else
        -- We can return stale
        return true
    end
end
_M.verify_stale_conditions = verify_stale_conditions


local function can_serve_stale_while_revalidate(res)
    return verify_stale_conditions(res, "stale-while-revalidate")
end
_M.can_serve_stale_while_revalidate = can_serve_stale_while_revalidate


local function can_serve_stale_if_error(res)
    return verify_stale_conditions(res, "stale-if-error")
end
_M.can_serve_stale_if_error = can_serve_stale_if_error


return _M
