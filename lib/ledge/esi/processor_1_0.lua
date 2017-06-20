local http = require "resty.http"
local cookie = require "resty.cookie"
local tag_parser = require "ledge.esi.tag_parser"
local util = require "ledge.util"

local   tostring, type, tonumber, next, unpack, pcall, setfenv =
        tostring, type, tonumber, next, unpack, pcall, setfenv

local str_sub = string.sub
local str_find = string.find
local str_len = string.len

local tbl_concat = table.concat
local tbl_insert = table.insert

local co_yield = coroutine.yield
local co_wrap = util.coroutine.wrap

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

local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _M = {
    _VERSION = '1.28.3',
}


function _M.new()
    return setmetatable({
        token = "ESI/1.0",
    }, get_fixed_field_metatable_proxy(_M))
end


local default_recursion_limit = 10

-- $1: variable name (e.g. QUERY_STRING)
-- $2: substructure key
-- $3: default value
-- $4: default value if quoted
local esi_var_pattern =
    [[\$\(([A-Z_]+){?([a-zA-Z\.\-~_%0-9]*)}?\|?(?:([^\s\)']+)|'([^\')]+)')?\)]]


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
        -- Evaluate request headers. Cookie and Accept-Language are special
        -- according to the spec.

        local header = str_sub(var_name, 6)
        local value = ngx_req_get_headers()[header]

        if not value then
            return default
        elseif header == "COOKIE" and key then
            local ck = cookie:new()
            local cookie_value = ck:get(key)
            return cookie_value or default
        elseif header == "ACCEPT_LANGUAGE" and key then
            -- If we're a table (multilple Accept-Language headers), convert
            -- to string
            if type(value) == "table" then
                value = tbl_concat(value, ", ")
            end

            if ngx_re_find(value, key, "oj") then
                return "true"
            else
                return "false"
            end

        elseif type(value) == "table" then
            -- For normal repeated headers, numeric indexes are supported
            key = tonumber(key)
            if key then
                -- We can index numerically (0 indexed)
                return tostring(value[key + 1] or default)
            else
                -- Without a numeric key, render as a comma separated list
                return tbl_concat(value, ", ") or default
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
                        return tostring(var[key] or default)
                    end
                else
                    if type(var) == "table" then
                        if var_name == "ESI_ARGS" then
                            -- The string version is the origin querystring
                            -- syntax (encoded)
                            return ngx.ctx.ledge_esi_args_encoded or default
                        else
                            -- No sane way to stringify other tables
                            return default
                        end
                    end
                    -- We're a string
                    return var or default
                end
            end
        end
        return default
    end
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure
local function _esi_gsub_in_vars_tags(m)
    local res = ngx_re_gsub(m[2], esi_var_pattern, esi_eval_var, "soj")
    return m[1] .. res .. m[3]
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure
local function _esi_gsub_in_when_test_tags(m)
    local vars = ngx_re_gsub(m[2], esi_var_pattern, function(m_var)
        local res = esi_eval_var(m_var)
        -- Quote unless we can be considered a number
        local number = tonumber(res)
        if number then
            return number
        else
            -- Strings must be enclosed in single quotes, so also backslash
            -- escape single quotes within the value
            return "\'" .. ngx_re_gsub(res, "'", "\\'", "oj") .. "\'"
        end
    end, "soj")

    return m[1] .. vars .. m[3]
end


-- Used in esi_replace_vars. Declared locally to avoid runtime closure
local function _esi_gsub_vars_in_other_tags(m)
    local vars = ngx_re_gsub(m[2], esi_var_pattern, esi_eval_var, "oj")
    return m[1] .. vars .. m[3]
end


local function _esi_condition_lexer(condition)
    -- ESI to Lua operators
    local op_replacements = {
        ["!="]  = "~=",
        ["|"]   = " or ",
        ["&"]   = " and ",
        ["||"]  = " or ",
        ["&&"]  = " and ",
        ["!"]   = " not ",
    }

    -- Mapping of types to types they are allowed to follow
    local lexer_rules = {
        number = {
            ["nil"] = true,
            ["operator"] = true,
        },
        string = {
            ["nil"] = true,
            ["operator"] = true,
        },
        operator = {
            ["nil"] = true,
            ["number"] = true,
            ["string"] = true,
            ["operator"] = true,
        },
    }

    -- $1: number
    -- $2: string
    -- $3: operator
    local p =[[(\d+(?:\.\d+)?)|(?:'(.*?)(?<!\\)')|(\!=|!|\|{1,2}|&{1,2}|={2}|=~|\(|\)|<=|>=|>|<)]]
    local ctx = {}
    local tokens = {}
    local prev_type
    local expecting_pattern = false

    repeat
        local token, err = ngx_re_match(condition, p, "", ctx)
        if token then
            local number, string, operator = token[1], token[2], token[3]
            local token_type

            if number then
                token_type = "number"
                tbl_insert(tokens, number)
            elseif string then
                token_type = "string"

                -- Check to see if we're expecing a regex pattern
                if expecting_pattern then
                    -- Extract the pattern and options
                    local re = ngx_re_match(
                        string,
                        [[\/(.*?)(?<!\\)\/([a-z]*)]],
                        "oj"
                    )
                    if not re then
                        ngx_log(ngx_INFO,
                            "Parse error: could not parse regular expression",
                            "in: \"", condition, "\""
                        )
                        return nil
                    else
                        local pattern, options = re[1], re[2]

                        -- The last item in tokens is the compare string.
                        -- Override this with a function call
                        local cmp_string = tokens[#tokens]
                        tokens[#tokens] =
                            "find(" .. cmp_string .. ", '" ..
                            pattern ..  "', '" .. options .. "oj')"
                    end
                    expecting_pattern = false
                else
                    -- Plain string literal
                    tbl_insert(tokens, "'" .. string .. "'")
                end
            elseif operator then
                token_type = "operator"

                -- Look for the regexp op
                if operator == "=~" then
                    if prev_type == "operator" then
                        ngx_log(ngx_INFO,
                            "Parse error: regular expression attempting ",
                            "against non-string in: \"", condition, "\""
                        )
                        return nil
                    else
                        -- Don't insert this operator, just set this flag and
                        -- look for the pattern in the next string
                        expecting_pattern = true
                    end
                else
                    -- Replace operators with Lua equivalents, if needed
                    tbl_insert(tokens, op_replacements[operator] or operator)
                end
            end

            -- If we break the rules, log a parse error and bail
            if prev_type then
                if not lexer_rules[prev_type][token_type] then
                    ngx_log(ngx_INFO,
                        "Parse error: found ", token_type, " after ", prev_type,
                        " in: \"", condition, "\""
                    )
                    return nil
                end
            end

            prev_type = token_type
        end
    until not token

    return true, tbl_concat(tokens or {}, " ")
end


local function _esi_evaluate_condition(condition)
    local ok, condition = _esi_condition_lexer(condition)
    if not ok then
        return false
    end

    -- Try to parse as Lua code, place in an empty sandbox, and pcall to
    -- evaluate the condition.
    local eval, err = loadstring("return " .. condition)
    if eval then
        -- Empty environment except an re.find function
        setfenv(eval, { find = ngx.re.find })

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
    -- First replace any variables in esi:when test="" tags, as these may need
    -- to be quoted for expression evaluation
    chunk = ngx_re_gsub(chunk,
        [[(<esi:when\s*test=\")(.+?)(\"\s*>(?:.*?))]],
        _esi_gsub_in_when_test_tags,
        "soj"
    )

    -- For every esi:vars block, substitute any number of variables found.
    chunk = ngx_re_gsub(chunk,
        "(<esi:[^>]+>)(.+?)(</esi:[^>]+>)",
        _esi_gsub_in_vars_tags,
        "soj"
    )

    -- Remove vars tags that are left over
    chunk = ngx_re_gsub(chunk,
        "(<esi:vars>|</esi:vars>)",
        "",
        "soj"
    )

    -- Replace vars inline in any other esi: tags, retaining the surrounding
    -- tags.
    chunk = ngx_re_gsub(chunk,
        [[(<esi:)([^>]+)([/\s]*>)]],
        _esi_gsub_vars_in_other_tags,
        "oj"
    )

    return chunk
end


local function esi_fetch_include(include_tag, buffer_size, pre_include_callback, recursion_limit)
    -- We track include recursion, and bail past the limit, yielding a special
    -- "esi:abort_includes" instruction which the outer process filter checks
    -- for.
    local recursion_count =
        tonumber(ngx_req_get_headers()["X-ESI-Recursion-Level"]) or 0

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

        -- If our upstream matches the current host, use server_addr /
        -- server_port instead. This keeps the connection local to this node
        -- where possible.
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
                    return nil
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
                    ["User-Agent"] =
                        httpc._USER_AGENT .. " ledge_esi/" .. _M._VERSION
                },
            }

            if pre_include_callback and
                type(pre_include_callback) == "function" then

                local ok, err = pcall(pre_include_callback, req_params)
                if not ok then
                    ngx_log(ngx_ERR,
                        "Error running esi_pre_include_callback: ", err
                    )
                end
            end

            -- Add these after the pre_include_callback so that they cannot be
            -- accidentally overriden
            req_params.headers["X-ESI-Parent-URI"] =
                ngx_var.scheme .. "://" .. ngx_var.host .. ngx_var.request_uri

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


local function process_escaping(chunk, res, recursion)
    if not recursion then recursion = 0 end
    if not res then res = {} end

    local parser = tag_parser.new(chunk)

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

    local parser = tag_parser.new(chunk)

    -- $1: the condition inside test=""
    local esi_when_pattern = [[(?:<esi:when)\s+(?:test="(.+?)"\s*>)]]
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

            -- If this ends up being the last choose tag, content after this
            -- should be output
            if ch_after then
                after = ch_after
            end

            local inner_parser = tag_parser.new(choose.contents)

            local when_found = false
            local when_matched = false
            local otherwise
            repeat
                local tag = inner_parser:next("esi:when|esi:otherwise")
                if tag and tag.closing then
                    if tag.tagname == "esi:when" and when_matched == false then
                        when_found = true

                        local function process_when(m_when)
                            -- We only show the first matching branch, others
                            -- must be removed even if they also match.
                            if when_matched then return "" end

                            local condition = m_when[1]
                            if _esi_evaluate_condition(condition) then
                                when_matched = true

                                if ngx_re_find(tag.contents, "<esi:choose>") then
                                    -- recurse
                                    evaluate_conditionals(
                                        tag.contents,
                                        res,
                                        recursion + 1
                                    )
                                else
                                    tbl_insert(res, tag.contents)
                                end
                            end
                            return ""
                        end

                        local when_res = ngx_re_sub(
                            tag.whole,
                            esi_when_pattern,
                            process_when
                        )

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
-- Acts as a sink when ESI instructions are not complete, buffering until the
-- chunk contains a full instruction safe to process on serve.
function _M.get_scan_filter(self, res)
    local reader = res.body_reader
    local esi_detected = false

    return co_wrap(function(buffer_size)
        local prev_chunk = ""
        local tag_hint

        repeat
            local chunk, err = reader(buffer_size)
            local has_esi = false

            if chunk then
                -- If we have a tag hint (partial opening ESI tag) from the
                -- previous chunk then prepend it here.
                if tag_hint then
                    chunk = tag_hint .. chunk
                    tag_hint = nil
                end

                -- prev_chunk will contain the last buffer if we have
                -- an ESI instruction spanning buffers.
                chunk = prev_chunk .. chunk

                local parser = tag_parser.new(chunk)

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

                        -- On first time, set res:set_and_save("has_esi", parser)
                        -- TODO: Need to get parser from somewhere?
                        if not esi_detected then
                            res:set_and_save("has_esi", self.token)
                            esi_detected = true
                        end

                        -- Trim chunk to what's left
                        chunk = after
                        prev_chunk = ""
                    elseif tag and not tag.whole then
                        -- Opening, but incompete. We yield up to this point
                        -- and buffer from the opening tag onwards, to try again.
                        -- This is so that we don't buffer the "before" content
                        -- if there turns out to be no closing tag
                        if before ~= "" then
                            co_yield(before, nil, false)
                        end

                        prev_chunk = tag.opening.tag .. after
                        break
                    else
                        -- No complete tag found, but look for something
                        -- resembling the beginning of an incomplete ESI tag
                        local start_from, start_to, err = ngx_re_find(
                            chunk,
                            "<(?:!--)?esi", "soj"
                        )
                        if start_from then
                            -- Incomplete opening tag, so buffer and try again
                            prev_chunk = chunk
                            break
                        end

                        -- Check the end of the chunk for the beginning of an
                        -- opening tag (a hint), incase it spans to the next
                        -- buffer.
                        local hint_match, err = ngx_re_match(
                            str_sub(chunk, -6, -1),
                            "(?:<!--es|<!--e|<!--|<es|<!-|<e|<!|<)$", "soj"
                        )

                        if hint_match then
                            tag_hint = hint_match[0]
                            -- Remove the hint from this chunk, it'll be
                            -- prepending to the next one.
                            chunk = str_sub(chunk, 1, - (#tag_hint + 1))
                        end


                        -- Nothing found, yield the whole chunk
                        co_yield(chunk, nil, false)
                        break
                    end
                until not tag
            elseif tag_hint then
                -- We had what looked like a tag_hint but there are no more
                -- chunks left.
                co_yield(tag_hint)
            end
        until not chunk
    end)
end


function _M.get_process_filter(self, res, pre_include_callback, recursion_limit)
    local recursion_count =
        tonumber(ngx_req_get_headers()["X-ESI-Recursion-Level"]) or 0

    local reader = res.body_reader

    -- We use an outer coroutine to filter the processed output in case we have
    -- to abort recursive includes.
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
                        chunk = ngx_re_gsub(chunk,
                            "<esi:comment (?:.*?)/>",
                            "",
                            "soj"
                        )

                        -- Remove 'remove' blocks
                        chunk = ngx_re_gsub(chunk,
                            "(<esi:remove>.*?</esi:remove>)",
                            "",
                            "soj"
                        )

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

                                -- This will be true if an include has
                                -- previously yielded the "esi:abort_includes
                                -- instruction.
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

        -- Outer filter, which checks for an esi:abort_includes instruction,
        -- so that we can handle accidental recursion.
        repeat
            local chunk, err = inner_reader(buffer_size)
            if chunk then
                -- If we see an abort instruction, we set a flag to stop
                -- further esi:includes.
                if ngx_re_find(chunk, "<esi:abort_includes", "soj") then
                    esi_abort_flag = true
                end

                -- We don't wish to see abort instructions in the final output,
                -- so the the top most request (recursion_count 0) is
                -- responsible for removing them.
                if recursion_count == 0 then
                    chunk = ngx_re_gsub(chunk,
                        "<esi:abort_includes />",
                        "",
                        "soj"
                    )
                end

                co_yield(chunk)
            end
        until not chunk
    end)
end


return _M
