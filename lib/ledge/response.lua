local h_util = require "ledge.header_util"
local http_headers = require "resty.http_headers"

local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local rawset = rawset
local rawget = rawget
local tonumber = tonumber
local tbl_concat = table.concat
local str_lower = string.lower
local str_gsub = string.gsub
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_match = ngx.re.match
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_req_get_headers = ngx.req.get_headers


local _M = {
    _VERSION = '1.28.3'
}

local mt = {
    __index = _M,
}

local NOCACHE_HEADERS = {
    ["Pragma"] = { "no-cache" },
    ["Cache-Control"] = {
        "no-cache",
        "no-store",
        "private",
    }
}


function _M.new()
    return setmetatable({
        uri = nil,
        status = nil,
        header = http_headers.new(),

        -- metadata
        remaining_ttl = 0,
        has_esi = false,

        -- body
        body_reader = function() return nil end,
    }, mt)
end


-- Setter for a fixed body string (not streamed)
function _M.set_body(self, body_string)
    local sent = false
    self.body_reader = function()
        if not sent then
            sent = true
            return body_string
        else
            return nil
        end
    end
end


function _M.is_cacheable(self)
    -- Never cache partial content
    local status = self.status
    if status == 206 or status == 416 then
        return false
    end

    for k,v in pairs(NOCACHE_HEADERS) do
        for i,h in ipairs(v) do
            if self.header[k] and self.header[k] == h then
                return false
            end
        end
    end

    if self:ttl() > 0 then
        return true
    else
        return false
    end
end


-- Calculates the TTL from response headers.
-- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
-- and finally Expires: HTTP_TIMESTRING.
function _M.ttl(self)
    local cc = self.header["Cache-Control"]
    if cc then
        if type(cc) == "table" then
            cc = tbl_concat(cc, ", ")
        end
        local max_ages = {}
        for max_age in ngx_re_gmatch(cc, [[(s-maxage|max-age)=(\d+)]], "ijo") do
            max_ages[max_age[1]] = max_age[2]
        end

        if max_ages["s-maxage"] then
            return tonumber(max_ages["s-maxage"])
        elseif max_ages["max-age"] then
            return tonumber(max_ages["max-age"])
        end
    end

    -- Fall back to Expires.
    local expires = self.header["Expires"]
    if expires then
        -- If there are multiple, last one wins
        if type(expires) == "table" then
            expires = expires[#expires]
        end

        local time = ngx_parse_http_time(tostring(expires))
        if time then return time - ngx_time() end
    end

    return 0
end


function _M.has_expired(self)
    return self.remaining_ttl <= 0
end


return _M
