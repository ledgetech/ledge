local h_util = require "ledge.header_util"

local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local rawset = rawset
local rawget = rawget
local tonumber = tonumber
local str_lower = string.lower
local str_gsub = string.gsub
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_match = ngx.re.match
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_req_get_headers = ngx.req.get_headers


local _M = {
    _VERSION = '0.3'
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


function _M.new(response)
    local body = ""
    local header = {}
    local status = nil

    if response then
        body = response.body
        header = response.header
        status = response.status
    end

    -- Header metatable for field case insensitivity.
    local header_mt = {
        normalised = {},
    }

    -- If we've seen this key in any case before, return it.
    header_mt.__index = function(t, k)
        k = str_gsub(str_lower(k), "-", "_")
        if header_mt.normalised[k] then
            return rawget(t, header_mt.normalised[k])
        end
    end

    -- First check the normalised table. If there's no match (first time) add an entry for 
    -- our current case in the normalised table. This is to preserve the human (prettier) case
    -- instead of outputting lowercased / underscored header names.
    --
    -- If there's a match, we're being updated, just with a different case for the key. We use
    -- the normalised table to give us the original key, and perorm a rawset().
    header_mt.__newindex = function(t, k, v)
        local k_low = str_gsub(str_lower(k), "-", "_")
        if not header_mt.normalised[k_low] then
            header_mt.normalised[k_low] = k 
            rawset(t, k, v)
        else
            rawset(t, header_mt.normalised[k_low], v)
        end
    end

    setmetatable(header, header_mt)

    return setmetatable({   status = status, 
                            body = body,
                            header = header, 
                            remaining_ttl = 0,
                            esi = {
                                has_esi_comment = nil,
                                has_esi_remove = nil,
                                has_esi_include = nil,
                                has_esi_vars = nil,
                            },
    }, mt)
end


function _M.is_cacheable(self)
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


function _M.ttl(self)
    -- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
    -- and finally Expires: HTTP_TIMESTRING.
    if self.header["Cache-Control"] then
        local max_ages = {}
        for max_age in ngx_re_gmatch(self.header["Cache-Control"], 
            "(s\\-maxage|max\\-age)=(\\d+)", 
            "io") do
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
        local time = ngx_parse_http_time(expires)
        if time then return time - ngx_time() end
    end

    return 0
end


function _M.has_expired(self)
    if self.remaining_ttl <= 0 then
        return true
    end

    local cc = ngx_req_get_headers()["Cache-Control"]
    if self.remaining_ttl - h_util.get_numeric_header_token(cc, "min-fresh") <= 0 then
        return true
    end
end


-- The amount of additional stale time allowed for this response considering
-- the current requests 'min-fresh'.
function _M.stale_ttl(self)
    -- Check response for headers that prevent serving stale
    local cc = self.header["Cache-Control"]
    if h_util.header_has_directive(cc, "revalidate") or
        h_util.header_has_directive(cc, "s-maxage") then
        return 0
    end

    local min_fresh = h_util.get_numeric_header_token(
        ngx_req_get_headers()["Cache-Control"], "min-fresh"
    )

    return self.remaining_ttl - min_fresh
end


-- Test for presence of esi comments and keep the result.
function _M.has_esi_comment(self)
    if self.esi.has_esi_comment == nil then
        if ngx_re_match(self.body, "<!--esi", "ioj") then
            self.esi.has_esi_comment = true
        else
            self.esi.has_esi_comment = false
        end
    end
    return self.esi.has_esi_comment
end


-- Test for the presence of esi:remove and keep the result.
function _M.has_esi_remove(self)
    if self.esi.has_esi_remove == nil then
        if ngx_re_match(self.body, "<esi:remove>", "ioj") then
            self.esi.has_esi_remove = true
        else
            self.esi.has_esi_remove = false
        end
    end
    return self.esi.has_esi_remove
end


function _M.has_esi_vars(self)
    if self.esi.has_esi_vars == nil then
        if ngx_re_match(self.body, "<esi:.*\\$\\([A-Z_].+\\)", "soj") then
            self.esi.has_esi_vars = true
        else
            self.esi.has_esi_vars = false
        end
    end
    return self.esi.has_esi_vars
end


-- Test for the presence of esi:include and keep the result.
function _M.has_esi_include(self)
    if self.esi.has_esi_include == nil then
        if ngx_re_match(self.body, "<esi:include", "ioj") then
            self.esi.has_esi_include = true
        else
            self.esi.has_esi_include = false
        end
    end
    return self.esi.has_esi_include
end


function _M.has_esi(self)
    return self:has_esi_vars() or self:has_esi_comment() or 
        self:has_esi_include() or self:has_esi_remove()
end


-- Reduce the cache lifetime and Last-Modified of this response to match
-- the newest / shortest in a given table of responses. Useful for esi:include.
function _M.minimise_lifetime(self, responses)
    for _,res in ipairs(responses) do
        local ttl = res:ttl()
        if ttl < self:ttl() then
            self.header["Cache-Control"] = "max-age="..ttl
            if self.header["Expires"] then
                self.header["Expires"] = ngx_http_time(ngx_time() + ttl)
            end
        end
        
        if res.header["Age"] and self.header["Age"] and 
            (tonumber(res.header["Age"]) < tonumber(self.header["Age"])) then
            self.header["Age"] = res.header["Age"]
        end

        if res.header["Last-Modified"] and self.header["Last-Modified"] then
            local res_lm = ngx_parse_http_time(res.header["Last-Modified"])
            if res_lm > ngx_parse_http_time(self.header["Last-Modified"]) then
                self.header["Last-Modified"] = res.header["Last-Modified"]
            end
        end
    end
end

return _M
