local type, tonumber, setmetatable =
    type, tonumber, setmetatable

local ngx_re_match = ngx.re.match
local ngx_re_find = ngx.re.find
local tbl_concat = table.concat


local _M = {
    _VERSION = "2.1.0"
}

local mt = {
    __index = _M,
}


-- Returns true if the directive appears in the header field value.
-- Set without_token to true to only return bare directives - i.e.
-- directives appearing with no =value part.
function _M.header_has_directive(header, directive, without_token)
    if header then
        if type(header) == "table" then header = tbl_concat(header, ", ") end

        local pattern = [[(?:\s*|,?)(]] .. directive .. [[)\s*(?:$|=|,)]]
        if without_token then
            pattern = [[(?:\s*|,?)(]] .. directive .. [[)\s*(?:$|,)]]
        end

        return ngx_re_find(header, pattern, "ioj") ~= nil
    end
    return false
end


function _M.get_header_token(header, directive)
    if _M.header_has_directive(header, directive) then
        if type(header) == "table" then header = tbl_concat(header, ", ") end

        -- Want the string value from a token
        local value = ngx_re_match(
            header,
            directive .. [[="?([a-z0-9_~!#%&/',`\$\*\+\-\|\^\.]+)"?]],
            "ioj"
        )
        if value ~= nil then
            return value[1]
        end
        return nil
    end
    return nil
end


function _M.get_numeric_header_token(header, directive)
    if _M.header_has_directive(header, directive) then
        if type(header) == "table" then header = tbl_concat(header, ", ") end

        -- Want the numeric value from a token
        local value = ngx_re_match(
            header,
            directive .. [[="?(\d+)"?]], "ioj"
        )
        if value ~= nil then
            return tonumber(value[1])
        end
    end
end

return setmetatable(_M, mt)
