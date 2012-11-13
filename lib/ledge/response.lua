module("ledge.response", package.seeall)

_VERSION = '0.1'

-- Cache states
local RESPONSE_STATE_UNKNOWN     = -99
local RESPONSE_STATE_PRIVATE     = -12
local RESPONSE_STATE_RELOADED    = -11
local RESPONSE_STATE_REVALIDATED = -10
local RESPONSE_STATE_SUBZERO     = -1
local RESPONSE_STATE_COLD        = 0
local RESPONSE_STATE_WARM        = 1
local RESPONSE_STATE_HOT         = 2

local class = ledge.response
local mt = { __index = class }


function new(self)
    local header = {}

    -- Header metatable for field case insensitivity.
    local header_mt = {
        normalised = {},
    }

    -- If we've seen this key in any case before, return it.
    header_mt.__index = function(t, k)
        k = k:lower():gsub("-", "_")
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
        k_low = k:lower():gsub("-", "_")
        if not header_mt.normalised[k_low] then
            header_mt.normalised[k_low] = k 
            rawset(t, k, v)
        else
            rawset(t, header_mt.normalised[k_low], v)
        end
    end

    setmetatable(header, header_mt)

    return setmetatable({   status = nil, 
                            body = "", 
                            header = header, 
                            remaining_ttl = 0,
                            state = RESPONSE_STATE_UNKNOWN,
                            __esi = {
                                has_esi_comment = nil,
                                has_esi_remove = nil,
                                has_esi_include = nil,
                            },
    }, mt)
end


function is_cacheable(self)
    local nocache_headers = {
        ["Pragma"] = { "no-cache" },
        ["Cache-Control"] = {
            "no-cache", 
            "no-store", 
            "private",
        }
    }

    for k,v in pairs(nocache_headers) do
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


function ttl(self)
    -- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
    -- and finally Expires: HTTP_TIMESTRING.
    if self.header["Cache-Control"] then
        local max_ages = {}
        for max_age in ngx.re.gmatch(self.header["Cache-Control"], 
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
    if self.header["Expires"] then 
        local time = ngx.parse_http_time(self.header["Expires"])
        if time then return time - ngx.time() end
    end

    return 0
end

-- Test for presence of esi comments and keep the result.
function has_esi_comment(self)
    if not self.__esi.has_esi_comment then
        if ngx.re.match(self.body, "<!--esi", "ioj") then
            self.__esi.has_esi_comment = true
        else
            self.__esi.has_esi_comment = false
        end
    end
    return self.__esi.has_esi_comment
end


-- Test for the presence of esi:remove and keep the result.
function has_esi_remove(self)
    if not self.__esi.has_esi_remove then
        if ngx.re.match(self.body, "<esi:remove>", "ioj") then
            self.__esi.has_esi_remove = true
        else
            self.__esi.has_esi_remove = false
        end
    end
    return self.__esi.has_esi_remove
end


-- Test for the presence of esi:include and keep the result.
function has_esi_include(self)
    if not self.__esi.has_esi_include then
        if ngx.re.match(self.body, "<esi:include", "ioj") then
            self.__esi.has_esi_include = true
        else
            self.__esi.has_esi_include = false
        end
    end
    return self.__esi.has_esi_include
end
