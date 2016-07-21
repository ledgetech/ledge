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

-- $1: everything inside the esi:choose tags
local esi_choose_pattern = [[(?:<esi:choose>\n?)(.+?)(?:</esi:choose>\n?)]]

-- $1: the condition inside test=""
-- $2: the contents of the branch
local esi_when_pattern = [[(?:<esi:when)\s+(?:test="(.+?)"\s*>\n?)(.*?)(?:</esi:when>\n?)]]

-- $1: the contents of the otherwise branch
local esi_otherwise_pattern = [[(?:<esi:otherwise>\n?)(.*?)(?:</esi:otherwise>\n?)]]

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


local function _esi_gsub_choose(m_choose)
    local matched = false

    local res = ngx_re_gsub(m_choose[1], esi_when_pattern, function(m_when)
        -- We only show the first matching branch, others must be removed
        -- even if they also match.
        if matched then return "" end

        local condition = m_when[1]
        local branch_contents = m_when[2]
        if _esi_evaluate_condition(condition) then
            matched = true
            return branch_contents
        end
        return ""
    end, "soj")

    -- Finally we replace the <esi:otherwise> block, either by removing
    -- it or rendering its contents
    local otherwise_replacement = ""
    if not matched then
        otherwise_replacement = "$1"
    end

    return ngx_re_sub(res, esi_otherwise_pattern, otherwise_replacement, "soj")
end


-- Replaces all variables in <esi:vars> blocks, or inline within other esi:tags.
-- Also removes the <esi:vars> tags themselves.
local function esi_replace_vars(chunk)
    -- First replace any variables in esi:when test="" tags, as these may need to be
    -- quoted for expression evaluation
    chunk = ngx_re_gsub(chunk,
        [[(<esi:when\s*test=\")(.+?)(\"\s*>(?:.*?)</esi:when>)]],
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


-- Reads from reader according to "buffer_size", and scans for ESI instructions.
-- Acts as a sink when ESI instructions are not complete, buffering until the chunk
-- contains a full instruction safe to process on serve.
function _M.get_scan_filter(reader)
    return co_wrap(function(buffer_size)
        local prev_chunk = ""
        local buffering = false
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

                -- prev_chunk will contain the last buffer if we have an ESI instruction spanning
                -- buffers.
                chunk = prev_chunk .. chunk
                local chunk_len = #chunk

                local pos = 1

                repeat
                    local is_comment = false

                    -- 1) look for an opening esi tag
                    local start_from, start_to, err = ngx_re_find(
                        str_sub(chunk, pos),
                        "<[!--]*esi", "soj"
                    )

                    if not start_from then
                        -- No complete opening tag found.
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

                        break
                    else
                        -- we definitely have something.
                        has_esi = true

                        -- give our start tag positions absolute chunk positions.
                        start_from = start_from + (pos - 1)
                        start_to = start_to + (pos - 1)

                        local e_from, e_to, err

                        -- 2) try and find the end of the tag (could be inline or block)
                        --    and comments and choose / when must be treated as special cases.
                        if str_sub(chunk, start_from, 7) == "<!--esi" then
                            e_from, e_to, err = ngx_re_find(
                                str_sub(chunk, start_to + 1),
                                "-->", "soj"
                            )
                        elseif str_sub(chunk, start_from, 12) == "<esi:choose>" then
                            -- This is a choose tag, and so we may have nested tags to deal with

                            -- We start after the first opening choose tag. Keep track of total depth and
                            -- current level to see if we can find enough closing tags to match our opening ones
                            local choose_depth = 1
                            local choose_level = 1

                            local f, t
                            local last_choose_from, last_choose_to
                            local search_from = start_from + 13 -- Start searching from the first opening choose

                            repeat
                                -- keep looking for opening or closing tags, track the depth / level
                                f, t = ngx_re_find(str_sub(chunk, search_from), "<([/]*)esi:choose>", "soj")
                                if f and t then
                                    last_choose_from = f
                                    last_choose_to = t
                                    local tag = str_sub(chunk, (search_from - 1) + f, (search_from - 1) + t)

                                    if tag == "<esi:choose>" then
                                        choose_depth = choose_depth + 1
                                        choose_level = choose_level + 1
                                    elseif tag == "</esi:choose>" then
                                        choose_level = choose_level - 1
                                    end
                                    search_from = search_from + t
                                end
                            until not f

                            -- if we're back to 0, we want to know where this closing tag is, so that we can yield
                            if choose_level == 0 then
                                e_from = last_choose_from
                                e_to = last_choose_to
                            end
                        else
                            -- Just look for a standard tag ending
                            e_from, e_to, err = ngx_re_find(
                                str_sub(chunk, start_to + 1),
                                "[^>]?/>|</esi:[^>]+>", "soj"
                            )
                        end

                        if not e_from then
                            -- the end isn't in this chunk, so we must buffer.
                            prev_chunk = chunk
                            buffering = true
                            break
                        else
                            -- we found the end of this instruction. stop buffering until we find
                            -- another unclosed instruction.
                            prev_chunk = ""
                            buffering = false

                            e_from = e_from + start_to
                            e_to = e_to + start_to

                            -- update pos for the next loop
                            pos = e_to + 1
                        end
                    end
                until pos >= chunk_len

                if not buffering then
                    -- we've got a chunk we can yield with.
                    co_yield(chunk, nil, has_esi)
                end
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
                        chunk, escaped = ngx_re_gsub(chunk, "(<!--esi(.*?)-->)", "$2", "soj")

                        -- Remove comments.
                        chunk = ngx_re_gsub(chunk, "<esi:comment (?:.*?)/>", "", "soj")

                        -- Remove 'remove' blocks
                        chunk = ngx_re_gsub(chunk, "(<esi:remove>.*?</esi:remove>)", "", "soj")

                        -- Evaluate and replace all esi vars
                        chunk = esi_replace_vars(chunk, buffer_size)

                        -- Evaluate choose / when / otherwise conditions...
                        chunk = ngx_re_gsub(chunk, esi_choose_pattern, _esi_gsub_choose, "soj")

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
                if str_find(chunk, "<esi:abort_includes", 1, true) then
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
