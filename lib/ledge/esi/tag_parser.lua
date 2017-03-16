local setmetatable, type =
    setmetatable, type

local str_sub = string.sub

local ngx_re_find = ngx.re.find
local ngx_re_match = ngx.re.match
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR


local _M = {
    _VERSION = '1.28',
}

local mt = {
    __index = _M,
    __newindex = function() error("module fields are read only", 2) end,
    __metatable = false,
}


function _M.new(content, offset)
    return setmetatable({
        content = content,
        pos = (offset or 0),
        open_comments = 0,
    }, mt)
end


function _M.next(self, tagname)
    local tag = self:find_whole_tag(tagname)
    local before, after
    if tag then
        before = str_sub(self.content, self.pos + 1, tag.opening.from - 1)

        if tag.closing then
            -- This is block level (with a closing tag)
            after = str_sub(self.content, tag.closing.to + 1)
            self.pos = tag.closing.to
        else
            -- Inline (no closing tag)
            after = str_sub(self.content, tag.opening.to + 1)
            self.pos = tag.opening.to
        end
    end

    return tag, before, after
end


function _M.open_pattern(tag)
    if tag == "!--esi" then
        return "<(!--esi)"
    else
        -- $1: the tag name, $2 the closing characters, e.g. "/>" or ">"
        return "<(" .. tag .. [[)(?:\s*(?:[a-z]+=\".+?(?<!\\)\"))?[^>]*?(?:\s*)(\/>|>)?]]
    end
end


function _M.close_pattern(tag)
    if tag == "!--esi" then
        return "-->"
    else
        -- $1: the tag name
        return "</(" .. tag .. ")\\s*>"
    end
end


function _M.either_pattern(tag)
    if tag == "!--esi" then
        return "(?:<(!--esi)|(-->))"
    else
        -- $1: the tag name, $2 the closing characters, e.g. "/>" or ">"
        return [[<[\/]?(]] .. tag .. [[)(?:\s*(?:[a-z]+=\".+?(?<!\\)\"))?[^>]*?(?:\s*)(\s*\\/>|>)?]]
    end
end


-- Finds the next esi tag, accounting for nesting to find the correct
-- matching closing tag etc.
function _M.find_whole_tag(self, tag)
    -- Only work on the remaining markup (after pos)
    local markup = str_sub(self.content, self.pos + 1)

    if not tag then
        -- Look for anything (including comment syntax)
        tag = "(?:!--esi)|(?:esi:[a-z]+)"
    end

    -- Find the first opening tag
    local opening_f, opening_t, err = ngx_re_find(markup, self.open_pattern(tag), "soj")
    if not opening_f then
        -- Nothing here
        return nil
    end

    -- We found an opening tag and has its position, but need to understand it better
    -- to handle comments and inline tags.
    local opening_m, err  = ngx_re_match(
        str_sub(markup, opening_f, opening_t),
        self.open_pattern(tag), "soj"
    )
    if not opening_m then
        ngx_log(ngx_ERR, err)
        return nil
    end

    -- We return a table with opening tag positions (absolute), as well as
    -- tag contents etc. Block level tags will have "closing" data too.
    local ret = {
        opening = {
            from = opening_f + self.pos,
            to = opening_t + self.pos,
            tag = str_sub(markup, opening_f, opening_t),
        },
        tagname = opening_m[1],
        closing = nil,
        contents = nil,
    }

    -- If this is an inline (non-block) tag, we have everything
    if type(opening_m[2]) == "string" and str_sub(opening_m[2], -2) == "/>" then
        ret.whole = str_sub(markup, opening_f, opening_t)
        return ret
    end

    -- We must be block level, and could potentially be nesting

    local search = opening_t -- We search from after the opening tag

    local f, t, closing_f, closing_t
    local depth = 1
    local level = 1

    repeat
        -- keep looking for opening or closing tags
        f, t = ngx_re_find(str_sub(markup, search + 1), self.either_pattern(ret.tagname), "soj")
        if f and t then
            -- Move closing markers along
            closing_f = f
            closing_t = t

            -- Track current level and total depth
            local tag = str_sub(markup, search + f, search + t)
            if ngx_re_find(tag, self.open_pattern(ret.tagname)) then
                depth = depth + 1
                level = level + 1
            elseif ngx_re_find(tag, self.close_pattern(ret.tagname)) then
                level = level - 1
            end
            -- Move search pos along
            search = search + t
        end
    until level == 0 or not f

    if closing_t and t then
        -- We have a complete block tag with the matching closing tag

        -- Make closing tag absolute
        closing_t = closing_t + search - t
        closing_f = closing_f + search - t

        ret.closing = {
            from = closing_f + self.pos,
            to = closing_t + self.pos,
            tag = str_sub(markup, closing_f, closing_t),
        }
        ret.contents = str_sub(markup, opening_t + 1, closing_f - 1)
        ret.whole = str_sub(markup, opening_f, closing_t)

        return ret
    else
        -- We have an opening block tag, but not the closing part. Return
        -- what we can as the filters will buffer until we find the rest.
        return ret
    end
end


return _M
