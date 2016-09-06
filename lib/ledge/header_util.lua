local ngx_re_match = ngx.re.match
local str_find = string.find
local str_gsub = string.gsub
local tbl_concat = table.concat


local _M = {
    _VERSION = 1.26
}

local mt = {
    __index = _M,
}


function _M.header_has_directive(header, directive)
    if header then
        if type(header) == "table" then header = tbl_concat(header, ", ") end

        -- Just checking the directive appears in the header, e.g. no-cache, private etc.
        return (str_find(header, directive, 1, true) ~= nil)
    end
    return false
end


function _M.get_header_token(header, directive)
    if _M.header_has_directive(header, directive) then
        if type(header) == "table" then header = tbl_concat(header, ", ") end

        -- Want the string value from a token
        local value = ngx_re_match(
            header, 
            str_gsub(directive, '-','\\-').."=\"?([a-z0-9_~!#%&/',`\\$\\*\\+\\-\\|\\^\\.]+)\"?", "ioj"
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
        str_gsub(directive, '-','\\-').."=\"?(\\d+)\"?", "ioj"
        )
        if value ~= nil then
            return tonumber(value[1])
        end
    end
end

return setmetatable(_M, mt)
