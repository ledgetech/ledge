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

    -- For case insensitve response headers, keep things proxied and normalised.
    local header_mt = {
        normalised = {},
    }

    header_mt.__index = function(t, k)
        k = k:lower():gsub("-", "_")
        return header_mt.normalised[k]
    end

    header_mt.__newindex = function(t, k, v)
        rawset(t, k, v)
        k = k:lower():gsub("-", "_")
        header_mt.normalised[k] = v
    end

    setmetatable(header, header_mt)

    return setmetatable({   status = nil, 
                            body = "", 
                            header = header, 
                            remaining_ttl = 0,
                            state = RESPONSE_STATE_UNKNOWN,
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
            if (self.header[k] and self.header[k] == h) then
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
        for _,p in ipairs({ "s%-maxage", "max%-age" }) do
            for h in self.header["Cache-Control"]:gmatch(p .. "=\"?(%d+)\"?") do 
                return tonumber(h)
            end
        end
    end

    -- Fall back to Expires.
    if self.header["Expires"] then 
        local time = ngx.parse_http_time(self.header["Expires"])
        if time then return time - ngx.time() end
    end

    return 0
end
