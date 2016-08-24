local http = require "resty.http"
local cookie = require "resty.cookie"

local   tostring, ipairs, pairs, type, tonumber, next, unpack, pcall =
        tostring, ipairs, pairs, type, tonumber, next, unpack, pcall

local str_sub = string.sub
local str_find = string.find
local str_len = string.len
local ngx_re_gsub = ngx.re.gsub
local ngx_re_sub = ngx.re.sub
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_find = ngx.re.find
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_crc32_long = ngx.crc32_long
local ngx_flush = ngx.flush
local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local tbl_concat = table.concat
local tbl_insert = table.insert
local co_yield = coroutine.yield
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume
local co_wrap = function(func)
    local co = co_create(func)
    if not co then
        return nil, "could not create coroutine"
    else
        return function(...)
            if co_status(co) == "suspended" then
                return select(2, co_resume(co, ...))
            else
                return nil, "can't resume a " .. co_status(co) .. " coroutine"
            end
        end
    end
end


local _M = {
    _VERSION = '0.04',
}


local default_recursion_limit = 10

-- $1: variable name (e.g. QUERY_STRING)
-- $2: substructure key
-- $3: default value
-- $4: default value if quoted
local esi_var_pattern = [[\$\(([A-Z_]+){?([a-zA-Z\.\-~_%0-9]*)}?\|?(?:([^\s\)']+)|'([^\')]+)')?\)]]

-- $1: the condition inside test=""
local esi_when_pattern = [[(?:<esi:when)\s+(?:test="(.+?)"\s*>)]]

-- Matches any lua reserved word
local lua_reserved_words =  "and|break|false|true|function|for|repeat|while|do|end|if|in|" ..
                            "local|nil|not|or|return|then|until|else|elseif"

-- $1: Any lua reserved words not found within quotation marks
local esi_non_quoted_lua_words =    [[(?!\'{1}|\"{1})(?:.*?)(\b]] .. lua_reserved_words ..
                                    [[\b)(?!\'{1}|\"{1})]]


-- Evaluates a given ESI variable.
local function esi_eval_var(var)
    -- Extract variables from capture results table
    local var_name = var[1] or ""

    local key = var[2]
    if key == "" then key = nil end

    local default = var[3]
    local default_quoted = var[4]
    local default = default or default_quoted or ""

    if var_name == "QUERY_STRING" then
        if not key then
            -- We don't have a key so give them the whole string
            return ngx_var.args or default
        else
            -- Lookup the querystring component by key
            local value = ngx_req_get_uri_args()[key]
            if value then
                if type(value) == "table" then
                    return tbl_concat(value, ", ")
                else
                    return value
                end
            else
                return default
            end
        end
    elseif str_sub(var_name, 1, 5) == "HTTP_" then
        local header = str_sub(var_name, 6)
        local value = ngx_req_get_headers()[header]

        if not value then
            return default
        elseif header == "COOKIE" and key then
            local ck = cookie:new()
            local cookie_value = ck:get(key)
            return cookie_value or default
        elseif header == "ACCEPT_LANGUAGE" and key then
            if ngx_re_find(value, key, "oj") then
                return "true"
            else
                return "false"
            end
        else
            return value
        end
    else
        local custom_variables = ngx.ctx.ledge_esi_custom_variables
        if custom_variables and type(custom_variables) == "table" then
            local var = custom_variables[var_name]
            if var then
                if key then
                    if type(var) == "table" then
                        return tostring(var[key]) or default
                    end
                else
                    if type(var) == "table" then var = default end
                    return var or default
                end
            end
        end
        return default
    end
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure definition.
local function _esi_gsub_in_vars_tags(m)
    return m[1] .. ngx_re_gsub(m[2], esi_var_pattern, esi_eval_var, "soj") .. m[3]
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure definition.
local function _esi_gsub_in_when_test_tags(m)
    local vars = ngx_re_gsub(m[2], esi_var_pattern, function(m_var)
        local res = esi_eval_var(m_var)
        -- Quote unless we can be considered a number
        local number = tonumber(res)
        if number then
            return number
        else
            return "\'" .. res .. "\'"
        end
    end, "soj")

    return m[1] .. vars .. m[3]
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure definition.
local function _esi_gsub_vars_in_other_tags(m)
    local vars = ngx_re_gsub(m[2], esi_var_pattern, esi_eval_var, "oj")
    return m[1] .. vars .. m[3]
end


local function _esi_evaluate_condition(condition)
    -- Remove lua reserved words (if / then / repeat / function etc)
    -- which are not quoted as strings
    local reps
    condition, reps = ngx_re_gsub(condition, esi_non_quoted_lua_words, "", "oj")
    if reps > 0 then
        ngx_log(ngx_INFO, "Removed " .. reps .. " unquoted Lua reserved words")
    end

    -- Replace ESI operand syntax with Lua equivalents.
    local op_replacements = {
        ["!="] = "~=",
        ["|"] = " or ",
        ["&"] = " and ",
        ["||"] = " or ",
        ["&&"] = " and ",
        ["!"] = " not ",
    }

    condition = ngx_re_gsub(condition, [[(\!=|!|\|{1,2}|&{1,2})]], function(m)
        return op_replacements[m[1]] or ""
    end, "soj")

    -- Try to parse as Lua code, place in an empty sandbox, and pcall to evaluate
    -- the condition.
    local eval, err = loadstring("return " .. condition)
    if eval then
        setfenv(eval, {})
        local ok, res = pcall(eval)
        if ok then
            return res
        else
            ngx_log(ngx_ERR, res)
            return false
        end
    else
        ngx_log(ngx_ERR, err)
        return false
    end
end


-- Replaces all variables in <esi:vars> blocks, or inline within other esi:tags.
-- Also removes the <esi:vars> tags themselves.
local function esi_replace_vars(chunk)
    -- First replace any variables in esi:when test="" tags, as these may need to be
    -- quoted for expression evaluation
    chunk = ngx_re_gsub(chunk,
        [[(<esi:when\s*test=\")(.+?)(\"\s*>(?:.*?))]],
        _esi_gsub_in_when_test_tags,
        "soj"
    )

    -- For every esi:vars block, substitute any number of variables found.
    chunk = ngx_re_gsub(chunk, "(<esi:[^>]+>)(.+?)(</esi:[^>]+>)", _esi_gsub_in_vars_tags, "soj")

    -- Remove vars tags that are left over
    chunk = ngx_re_gsub(chunk, "(<esi:vars>|</esi:vars>)", "", "soj")

    -- Replace vars inline in any other esi: tags, retaining the surrounding tags.
    chunk = ngx_re_gsub(chunk, [[(<esi:)([^>]+)([/\s]*>)]], _esi_gsub_vars_in_other_tags, "oj")

    return chunk
end


local function esi_fetch_include(include_tag, buffer_size, pre_include_callback, recursion_limit)
    -- We track include recursion, and bail past the limit, yielding a special "esi:abort_includes"
    -- instruction which the outer process filter checks for.
    local recursion_count = tonumber(ngx_req_get_headers()["X-ESI-Recursion-Level"]) or 0
    if recursion_count >= recursion_limit then
        ngx_log(ngx_ERR, "ESI recursion limit (", recursion_limit, ") exceeded")
        co_yield("<esi:abort_includes />")
        return nil
    end

    local src, err = ngx_re_match(
        include_tag,
        [[src="([^"]+)"]],
        "oj"
    )

    if src then
        local httpc = http.new()

        local scheme, host, port, path
        local uri_parts = httpc:parse_uri(src[1])

        if not uri_parts then
            -- Not a valid URI, so probably a relative path. Resolve
            -- local to the current request.
            scheme = ngx_var.scheme
            host = ngx_var.http_host or ngx_var.host
            port = ngx_var.server_port
            path = src[1]

            -- No leading slash means we have a relative path. Append
            -- this to the current URI.
            if str_sub(path, 1, 1) ~= "/" then
                path = ngx_var.uri .. "/" .. path
            end
        else
            scheme, host, port, path = unpack(uri_parts)
        end

        local upstream = host

        -- If our upstream matches the current host, use server_addr / server_port
        -- instead. This keeps the connection local to this node where possible.
        if upstream == ngx_var.http_host then
            upstream = ngx_var.server_addr
            port = ngx_var.server_port
        end

        local res, err = httpc:connect(upstream, port)
        if not res then
            ngx_log(ngx_ERR, err, " connecting to ", upstream,":", port)
            return nil
        else
            if scheme == "https" then
                local ok, err = httpc:ssl_handshake(false, host, false)
                if not ok then
                    ngx_log(ngx_ERR, "ssl handshake failed: ", err)
                end
            end

            local parent_headers = ngx_req_get_headers()

            local req_params = {
                method = "GET",
                path = ngx_re_gsub(path, "\\s", "%20", "jo"),
                headers = {
                    ["Host"] = host,
                    ["Cookie"] = parent_headers["Cookie"],
                    ["Cache-Control"] = parent_headers["Cache-Control"],
                    ["Authorization"] = parent_headers["Authorization"],
                    ["User-Agent"] = httpc._USER_AGENT .. " ledge_esi/" .. _M._VERSION
                },
            }

            if pre_include_callback and type(pre_include_callback) == "function" then
                local ok, err = pcall(pre_include_callback, req_params)
                if not ok then
                    ngx_log(ngx_ERR, "Error running esi_pre_include_callback: ", err)
                end
            end

            -- Add these after the pre_include_callback so that they cannot be accidentally overriden
            req_params.headers["X-ESI-Parent-URI"] = ngx_var.scheme .. "://" .. ngx_var.host .. ngx_var.request_uri
            req_params.headers["X-ESI-Recursion-Level"] = recursion_count + 1

            local res, err = httpc:request(req_params)

            if not res then
                ngx_log(ngx_ERR, err, " from ", (src[1] or ''))
                return nil
            elseif res.status >= 500 then
                ngx_log(ngx_ERR, res.status, " from ", (src[1] or ''))
                return nil
            else
                if res then
                    -- Stream the include fragment, yielding as we go
                    local reader = res.body_reader
                    repeat
                        local ch, err = reader(buffer_size)
                        if ch then
                            co_yield(ch)
                        end
                    until not ch
                end
            end

            httpc:set_keepalive()
        end
    end
end


-- ==================================================================
-- esi_parser, allows us to walk when / choose / otherwise statements
-- ==================================================================

local esi_parser = {}
local _esi_parser_mt = { __index = esi_parser }


function esi_parser.new(content, offset)
    return setmetatable({
        content = content,
        pos = (offset or 0),
        open_comments = 0,
    }, _esi_parser_mt)
end


function esi_parser.next(self, tagname)
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


function esi_parser.open_pattern(tag)
    if tag == "!--esi" then
        return "<(!--esi)"
    else
        -- $1: the tag name, $2 the closing characters, e.g. "/>" or ">"
        return "<(" .. tag .. ")(?:\\s*(?:[a-z]+=\".+?\"))?[^>]*?(?:\\s*)(\\/>|>)?"
    end
end


function esi_parser.close_pattern(tag)
    if tag == "!--esi" then
        return "-->"
    else
        -- $1: the tag name
        return "</(" .. tag .. ")\\s*>"
    end
end


function esi_parser.either_pattern(tag)
    if tag == "!--esi" then
        return "(?:<(!--esi)|(-->))"
    else
        -- $1: the tag name, $2 the closing characters, e.g. "/>" or ">"
        return "<[\\/]?(" .. tag .. ")(?:\\s*(?:[a-z]+=\".+?\"))?[^>]*?(?:\\s*)(\\s*\\/>|>)?"
    end
end


-- Finds the next esi tag, accounting for nesting to find the correct
-- matching closing tag etc.
function esi_parser.find_whole_tag(self, tag)
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
    -- tag contents etc. Blocl level tags will have "closing" data too.
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


local function process_escaping(chunk, res, recursion)
    if not recursion then recursion = 0 end
    if not res then res = {} end

    local parser = esi_parser.new(chunk)

    local chunk_has_escaping = false
    repeat
        local tag, before, after = parser:next("!--esi")
        if tag and tag.closing then
            chunk_has_escaping = true
            if before then
                tbl_insert(res, before)
            end

            -- If there are more nested, recurse
            if ngx_re_find(tag.contents, "<!--esi", "soj") then
                return process_escaping(tag.contents, res, recursion)
            else
                tbl_insert(res, tag.contents)
                tbl_insert(res, after)
            end

        end

    until not tag

    if chunk_has_escaping then
        return tbl_concat(res)
    else
        return chunk
    end
end


-- Assumed chunk contains a complete conditional instruction set. Handles
-- recursion for nested conditions.
local function evaluate_conditionals(chunk, res, recursion)
    if not recursion then recursion = 0 end
    if not res then res = {} end

    local parser = esi_parser.new(chunk)

    local after -- Will contain anything after the last closing choose tag
    local chunk_has_conditionals = false
    repeat
        local choose, ch_before, ch_after = parser:next("esi:choose")
        if choose and choose.closing then
            chunk_has_conditionals = true

            -- Anything before this choose should just be output
            if ch_before then
                tbl_insert(res, ch_before)
            end

            -- If this ends up being the last choose tag, content after this should be output
            if ch_after then
                after = ch_after
            end

            local inner_parser = esi_parser.new(choose.contents)

            local when_found = false
            local when_matched = false
            local otherwise
            repeat
                local tag = inner_parser:next("esi:when|esi:otherwise")
                if tag and tag.closing then
                    if tag.tagname == "esi:when" and when_matched == false then
                        when_found = true

                        local when_res = ngx_re_sub(tag.whole, esi_when_pattern, function(m_when)
                            -- We only show the first matching branch, others must be removed
                            -- even if they also match.
                            if when_matched then return "" end

                            local condition = m_when[1]
                            if _esi_evaluate_condition(condition) then
                                when_matched = true

                                if ngx_re_find(tag.contents, "<esi:choose>") then
                                    -- recurse
                                    evaluate_conditionals(tag.contents, res, recursion + 1)
                                else
                                    tbl_insert(res, tag.contents)
                                end
                            end
                            return ""
                        end, "soj")

                        -- Break after the first winning expression
                    elseif tag.tagname == "esi:otherwise" then
                        otherwise = tag.contents
                    end
                end
            until not tag

            if not when_matched and otherwise then
                if ngx_re_find(otherwise, "<esi:choose>") then
                    -- recurse
                    evaluate_conditionals(otherwise, res, recursion + 1)
                else
                    tbl_insert(res, otherwise)
                end
            end
        end

    until not choose

    if after then
        tbl_insert(res, after)
    end

    if not chunk_has_conditionals then
        return chunk
    else
        return tbl_concat(res)
    end
end


-- Reads from reader according to "buffer_size", and scans for ESI instructions.
-- Acts as a sink when ESI instructions are not complete, buffering until the chunk
-- contains a full instruction safe to process on serve.
function _M.get_scan_filter(reader)
    return co_wrap(function(buffer_size)
        local prev_chunk = ""
        local tag_hint

        repeat
            local chunk, err = reader(buffer_size)
            local has_esi = false

            if chunk then
                -- If we have a tag hint (partial opening ESI tag) from the previous chunk
                -- then prepend it here.
                if tag_hint then
                    chunk = tag_hint .. chunk
                    tag_hint = nil
                end

                -- prev_chunk will contain the last buffer if we have
                -- an ESI instruction spanning buffers.
                chunk = prev_chunk .. chunk

                local parser = esi_parser.new(chunk)

                repeat
                    local tag, before, after = parser:next()

                    if tag and tag.whole then
                        -- We have a whole instruction

                        -- Yield anything before this tag
                        if before ~= "" then
                            co_yield(before, nil, false)
                        end

                        -- Yield the entire tag with has_esi=true
                        co_yield(tag.whole, nil, true)

                        -- Trim chunk to what's left
                        chunk = after
                        prev_chunk = ""
                    elseif tag and not tag.whole then
                        -- Opening, but incompete. We yield up to this point and buffer from
                        -- the opening tag onwards, to try again.
                        -- This is so that we don't buffer the "before" content if there turns
                        -- out to be no closing tag
                        if before ~= "" then
                            co_yield(before, nil, false)
                        end

                        prev_chunk = tag.opening.tag .. after
                        break
                    else
                        -- No complete tag found, but look for something resembling
                        -- the beginning of an incomplete ESI tag
                        local start_from, start_to, err = ngx_re_find(
                            chunk,
                            "<(?:!--)?esi", "soj"
                        )
                        if start_from then
                            -- Incomplete opening tag, so buffer and try again
                            prev_chunk = chunk
                            break
                        end

                        -- Check the end of the chunk for the beginning of an opening tag (a hint),
                        -- incase it spans to the next buffer.
                        local hint_match, err = ngx_re_match(
                            str_sub(chunk, -6, -1),
                            "(?:<!--es|<!--e|<!--|<es|<!-|<e|<!|<)$", "soj"
                        )

                        if hint_match then
                            tag_hint = hint_match[0]
                            -- Remove the hint from this chunk, it'll be prepending to the next one.
                            chunk = str_sub(chunk, 1, - (#tag_hint + 1))
                        end


                        -- Nothing found, yield the whole chunk
                        co_yield(chunk, nil, false)
                        break
                    end
                until not tag
            elseif tag_hint then
                -- We had what looked like a tag_hint but there are no more chunks
                co_yield(tag_hint)
            end
        until not chunk
    end)
end


function _M.get_process_filter(reader, pre_include_callback, recursion_limit)
    local recursion_count = tonumber(ngx_req_get_headers()["X-ESI-Recursion-Level"]) or 0

    -- We use an outer coroutine to filter the processed output in case we have to
    -- abort recursive includes.
    return co_wrap(function(buffer_size)
        local esi_abort_flag = false

        -- This is the actual process filter coroutine
        local inner_reader = co_wrap(function(buffer_size)
            repeat
                local chunk, err, has_esi = reader(buffer_size)
                local escaped = 0
                if chunk then

                    if has_esi then
                        -- Remove <!--esi-->
                        chunk = process_escaping(chunk)

                        -- Remove comments.
                        chunk = ngx_re_gsub(chunk, "<esi:comment (?:.*?)/>", "", "soj")

                        -- Remove 'remove' blocks
                        chunk = ngx_re_gsub(chunk, "(<esi:remove>.*?</esi:remove>)", "", "soj")

                        -- Evaluate and replace all esi vars
                        chunk = esi_replace_vars(chunk)

                        -- Evaluate choose / when / otherwise conditions...
                        chunk = evaluate_conditionals(chunk)

                        -- Find and loop over esi:include tags
                        local re_ctx = { pos = 1 }
                        local yield_from = 1
                        repeat
                            local from, to, err = ngx_re_find(
                                chunk,
                                [[<esi:include\s*src="[^"]+"\s*/>]],
                                "oj",
                                re_ctx
                            )

                            if from then
                                -- Yield up to the start of the include tag
                                co_yield(str_sub(chunk, yield_from, from - 1))
                                ngx_flush()
                                yield_from = to + 1

                                -- This will be true if an include has previously yielded
                                -- the "esi:abort_includes instruction.
                                if esi_abort_flag == false then
                                    -- Fetches and yields the streamed response
                                    esi_fetch_include(
                                        str_sub(chunk, from, to),
                                        buffer_size,
                                        pre_include_callback,
                                        recursion_limit
                                    )
                                end
                            else
                                if yield_from == 1 then
                                    -- No includes found, yield everything
                                    co_yield(chunk)
                                else
                                    -- No *more* includes, yield what's left
                                    co_yield(str_sub(chunk, re_ctx.pos, -1))
                                end
                            end

                        until not from
                    else
                        co_yield(chunk)
                    end
                end
            until not chunk
        end)

        -- Outer filter, which checks for an esi:abort_includes instruction, so that
        -- we can handle accidental recursion.
        repeat
            local chunk, err = inner_reader(buffer_size)
            if chunk then
                -- If we see an abort instruction, we set a flag to stop further esi:includes.
                if ngx_re_find(chunk, "<esi:abort_includes", "soj") then
                    esi_abort_flag = true
                end

                -- We don't wish to see abort instructions in the final output, so the the top most
                -- request (recursion_count 0) is responsible for removing them.
                if recursion_count == 0 then
                    chunk = ngx_re_gsub(chunk, "<esi:abort_includes />", "", "soj")
                end

                co_yield(chunk)
            end
        until not chunk
    end)
end


return _M
