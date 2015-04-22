local http = require "resty.http"
local cookie = require "resty.cookie"

local   tostring, ipairs, pairs, type, tonumber, next, unpack, pcall =
        tostring, ipairs, pairs, type, tonumber, next, unpack, pcall

local str_sub = string.sub
local ngx_re_gsub = ngx.re.gsub
local ngx_re_sub = ngx.re.sub
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_find = ngx.re.find
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local tbl_concat = table.concat
local co_yield = coroutine.yield
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume

-- Reimplemented coroutine.wrap, returning "nil, err" if the coroutine cannot
-- be resumed. This protects user code from inifite loops when doing things like
-- repeat
--   local chunk, err = res.body_reader()
--   if chunk then -- <-- This could be a string msg in the core wrap function.
--     ...
--   end
-- until not chunk
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
    _VERSION = '0.01',
}


-- $1: variable name (e.g. QUERY_STRING)
-- $2: substructure key
-- $3: default value
-- $4: default value if quoted
local esi_var_pattern = [[\$\(([A-Z_]+){?([a-zA-Z\.\-~_%0-9]*)}?\|?(?:([^\s\)']+)|'([^\')]+)')?\)]]

-- $1: everything inside the esi:choose tags
local esi_choose_pattern = [[(?:<esi:choose>\n?)(.+)(?:</esi:choose>\n?)]]

-- $1: the condition inside test=""
-- $2: the contents of the branch
local esi_when_pattern = [[(?:<esi:when)\s+(?:test="(.+?)"\s*>\n?)(.*?)(?:</esi:when>\n?)]]

-- $1: the contents of the otherwise branch 
local esi_otherwise_pattern = [[(?:<esi:otherwise>\n?)(.*)(?:</esi:otherwise>\n?)]]

-- Matches any lua reserved word
local lua_reserved_words =  "and|break|false|true|function|for|repeat|while|do|end|if|in|" ..
                            "local|nil|not|or|return|then|until|else|elseif"

-- $1: Any lua reserved words not found within quotation marks
local esi_non_quoted_lua_words =    [[(?!\'{1}|\"{1})(?:.*)(\b]] .. lua_reserved_words .. 
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
    return ngx_re_gsub(m[1], esi_var_pattern, esi_eval_var, "soj")
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
    condition = ngx_re_gsub(condition, esi_non_quoted_lua_words, "", "oj")
    
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
    chunk = ngx_re_gsub(chunk, "<esi:vars>(.*)</esi:vars>", _esi_gsub_in_vars_tags, "soj")

    -- Remove vars tags that are left over
    chunk = ngx_re_gsub(chunk, "(<esi:vars>|</esi:vars>)", "", "soj")

    -- Replace vars inline in any other esi: tags, retaining the surrounding tags.
    chunk = ngx_re_gsub(chunk, "(<esi:)(.+)(.*>)", _esi_gsub_vars_in_other_tags, "oj")

    return chunk
end


local function esi_fetch_include(include_tag, buffer_size)
    local src, err = ngx_re_match(
        include_tag,
        "src=\"(.+)\".*/>",
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
            ngx_log(ngx_ERR, err)
            co_yield()
        else
            local headers = ngx_req_get_headers()

            -- Remove client validators
            headers["if-modified-since"] = nil
            headers["if-none-match"] = nil

            headers["host"] = host
            headers["accept-encoding"] = nil

            local res, err = httpc:request{ 
                method = ngx_req_get_method(),
                path = path,
                headers = headers,
            }
            
            if not res then
                ngx_log(ngx_ERR, err)
                co_yield()
            elseif res.status >= 500 then
                ngx_log(ngx_ERR, res.status)
                co_yield()
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

        repeat
            local chunk, err = reader(buffer_size)
            local has_esi = false

            if chunk then
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
                        -- nothing to do in this chunk, stop looping.
                        break
                    else
                        -- we definitely have something.
                        has_esi = true

                        -- give our start tag positions absolute chunk positions.
                        start_from = start_from + (pos - 1)
                        start_to = start_to + (pos - 1)

                        local e_from, e_to, err

                        -- 2) try and find the end of the tag (could be inline or block)
                        --    and comments must be treated as special cases.
                        if str_sub(chunk, start_from, 7) == "<!--esi" then
                            e_from, e_to, err = ngx_re_find(
                                str_sub(chunk, start_to + 1),
                                "-->", "soj"
                            )
                        else
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
                    co_yield(chunk, has_esi)
                end
            end
        until not chunk
    end)
end


function _M.get_process_filter(reader)
    return co_wrap(function(buffer_size)
        local i = 1
        repeat
            local chunk, has_esi, err = reader(buffer_size)
            if chunk then
                if has_esi then
                    -- Remove comments
                    chunk = ngx_re_gsub(chunk, "(<!--esi(.*?)-->)", "$2", "soj")

                    -- Remove 'remove' blocks
                    chunk = ngx_re_gsub(chunk, "(<esi:remove>.*?</esi:remove>)", "", "soj")

                    -- Evaluate and replace all esi vars
                    chunk = esi_replace_vars(chunk, buffer_size)

                    -- Evaluate choose / when / otherwise conditions...
                    chunk = ngx_re_gsub(chunk, esi_choose_pattern, _esi_gsub_choose, "soj")

                    -- Find and loop over esi:include tags
                    local ctx = { pos = 1 }
                    local yield_from = 1
                    repeat
                        local from, to, err = ngx_re_find(
                            chunk, 
                            "<esi:include src=\".+\".*/>", 
                            "oj", 
                            ctx
                        )

                        if from then
                            -- Yield up to the start of the include tag
                            co_yield(str_sub(chunk, yield_from, from - 1))
                            yield_from = to + 1

                            -- Fetches and yields the streamed response
                            esi_fetch_include(str_sub(chunk, from, to))
                        else
                            if yield_from == 1 then
                                -- No includes found, yield everything
                                co_yield(chunk)
                            else
                                -- No *more* includes, yield what's left
                                co_yield(str_sub(chunk, ctx.pos, #chunk))
                            end
                        end

                    until not from
                else
                    co_yield(chunk)
                end
            end

            i = i + 1
        until not chunk
    end)
end


return _M
