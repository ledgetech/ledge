local tonumber = tonumber
local setmetatable = setmetatable
local ngx = ngx

module(...)

_VERSION = "0.01"

local mt = { __index = _M }


function header_has_directive(header, directive)
    if header then
        -- Just checking the directive appears in the header, e.g. no-cache, private etc.
        return (header:find(directive, 1, true) ~= nil)
    end
    return false
end


function get_header_token(header, directive)
    if header_has_directive(header, directive) then
        -- Want the string value from a token
        local value = ngx.re.match(header, directive:gsub('-','\\-').."=\"?([a-z0-9_~!#%&'`\\$\\*\\+\\-\\|\\^\\.]+)\"?", "ioj")
        if value ~= nil then
            return value[1]
        end
        return nil
    end
    return nil
end


function get_numeric_header_token(header, directive)
    if header_has_directive(header, directive) then
        -- Want the numeric value from a token
        local value = ngx.re.match(header, directive:gsub('-','\\-').."=\"?(\\d+)\"?", "ioj")
        if value ~= nil then
            return tonumber(value[1])
        end
        return 0
    end
    return 0
end


local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}


setmetatable(_M, class_mt)
