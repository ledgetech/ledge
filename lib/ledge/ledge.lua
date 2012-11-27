local setmetatable = setmetatable
local error = error
local assert = assert
local require = require
local ipairs = ipairs
local pairs = pairs
local unpack = unpack
local tostring = tostring
local tonumber = tonumber
local type = type
local table = table
local ngx = ngx
local coroutine = coroutine

module(...)

_VERSION = '0.06'

local mt = { __index = _M }

local redis = require("resty.redis")
local response = require("ledge.response")


-- Origin modes, for serving stale content during maintenance periods or emergencies.
ORIGIN_MODE_BYPASS = 1 -- Never goes to the origin, serve from cache where possible or 503.
ORIGIN_MODE_AVOID  = 2 -- Avoids going to the origin, serving from cache where possible.
ORIGIN_MODE_NORMAL = 4 -- Assume the origin is happy, use at will.


function new(self)
    local config = {
        origin_location = "/__ledge_origin",
        redis_host      = "127.0.0.1",
        redis_port      = 6379,
        redis_socket    = nil,
        redis_database  = 0,
        redis_timeout   = nil,          -- Defaults to 60s or lua_socket_read_timeout
        redis_keepalive_timeout = nil,  -- Defaults to 60s or lua_socket_keepalive_timeout
        redis_keepalive_poolsize = nil, -- Defaults to 30 or lua_socket_pool_size
        keep_cache_for  = 86400 * 30,   -- Max time to Keep cache items past expiry + stale (sec)
        origin_mode     = ORIGIN_MODE_NORMAL,
        max_stale       = nil,          -- Warning: Violates HTTP spec
        background_revalidate = false,
        enable_esi      = false,
    }

    return setmetatable({ config = config }, mt)
end


function run(self)
    -- Off we go then.. enter the ST_INIT state.
    self:ST_INIT()
end


function purge(self)
    -- Purge request
    self:ST_PURGING()
end


-- UTILITIES --------------------------------------------------


-- A safe place in ngx.ctx for the current module instance (self).
function ctx(self)
    local id = tostring(self)
    local ctx = ngx.ctx[id]
    if not ctx then
        ctx = {
            events = {},
            config = {},
            state_history = {},
        }
        ngx.ctx[id] = ctx
    end
    return ctx
end


-- Keeps track of the transition history.
function transition(self, state)
    self:ctx().state_history[state] = true
end


function relative_uri()
    return ngx.var.uri .. ngx.var.is_args .. (ngx.var.query_string or "")
end


function full_uri()
    return ngx.var.scheme .. '://' .. ngx.var.host .. relative_uri()
end


function visible_hostname()
    local name = ngx.var.visible_hostname or ngx.var.hostname
    if ngx.var.server_port ~= "80" and ngx.var.server_port ~= "443" then
        name = name .. ":" .. ngx.var.server_port
    end
    return name
end


function redis_connect(self)
    -- Connect to Redis. The connection is kept alive later.
    self:ctx().redis = redis:new()
    if self:config_get("redis_timeout") then
        self:ctx().redis:set_timeout(self:config_get("redis_timeout"))
    end

    local ok, err = self:ctx().redis:connect(
        self:config_get("redis_socket") or self:config_get("redis_host"),
        self:config_get("redis_port")
    )

    -- If we couldn't connect for any reason, redirect to the origin directly.
    -- This means if Redis goes down, the site stands a chance of still being up.
    if not ok then
        ngx.log(ngx.WARN, err .. ", internally redirecting to the origin")
        return ngx.exec(self:config_get("origin_location")..relative_uri())
    end

    -- redis:select always returns OK
    if self:config_get("redis_database") > 0 then
        self:ctx().redis:select(self:config_get("redis_database"))
    end
end


function redis_close(self)
    -- Background revalidation running, don't close redis yet
    if self:ctx()['bg_thread'] ~= nil then
        ngx.thread.wait(self:ctx()['bg_thread'])
    end

    -- Keep the Redis connection based on keepalive settings.
    local ok, err = nil
    if self:config_get("redis_keepalive_timeout") then
        if self:config_get("redis_keepalive_pool_size") then
            ok, err = self:ctx().redis:set_keepalive(
                self:config_get("redis_keepalive_timeout"),
                self:config_get("redis_keepalive_pool_size")
            )
        else
            ok, err = self:ctx().redis:set_keepalive(self:config_get("redis_keepalive_timeout"))
        end
    else
        ok, err = self:ctx().redis:set_keepalive()
    end

    if not ok then
        ngx.log(ngx.WARN, "couldn't set keepalive, "..err)
    end
end


function accepts_stale(self, res)
    -- max_stale config overrides everything
    local max_stale = self:config_get("max_stale")
    if max_stale and max_stale > 0 then
        return max_stale
    end

    -- Check response for headers that prevent serving stale
    local res_cc = res.header["Cache-Control"]
    if self:header_has_directive(res_cc, 'revalidate') or self:header_has_directive(res_cc, 's-maxage') then
        return nil
    end

    -- Check for max-stale request header
    local req_cc = ngx.req.get_headers()['Cache-Control']
    return self:get_numeric_header_token(req_cc, 'max-stale')
end


function calculate_stale_ttl(self, res)
    local stale = self:accepts_stale(res) or 0
    local min_fresh = self:get_numeric_header_token(ngx.req.get_headers()['Cache-Control'], 'min-fresh')

    return (res.remaining_ttl - min_fresh) + stale
end


function request_accepts_cache(self)
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        return false
    end

    -- Ignore the client requirements if we're not in "NORMAL" mode.
    if self:config_get("origin_mode") < ORIGIN_MODE_NORMAL then
        return true
    end

    -- Check for no-cache
    local h = ngx.req.get_headers()
    if h["Cache-Control"] == "no-cache" or h["Pragma"] == "no-cache" then
        return false
    end

    return true
end


function must_revalidate(self)
    local cc = ngx.req.get_headers()["Cache-Control"]
    if cc == "max-age=0" then
        return true
    else
        local res = self:get_response()
        if res.header["Cache-Control"]:find("revalidate") then
            return true
        elseif type(cc) == "string" and res.header["Age"] then
            local max_age = cc:match("max%-age=(%d+)")
            if max_age and res.header["Age"] > tonumber(max_age) then
                return true
            end
        end
    end
    return false
end


function can_revalidate_locally(self)
    local req_h = ngx.req.get_headers()
    if  req_h["If-Modified-Since"] or req_h["If-None-Match"] then
        return true
    else
        return false
    end
end


function is_valid_locally(self)
    local req_h = ngx.req.get_headers()
    local res = self:get_response()

    if res.header["Last-Modified"] and req_h["If-Modified-Since"] then
        -- If Last-Modified is newer than If-Modified-Since.
        if ngx.parse_http_time(res.header["Last-Modified"])
            > ngx.parse_http_time(req_h["If-Modified-Since"]) then
            return false
        end
    end

    if res.header["Etag"] and req_h["If-None-Match"] then
        if res.header["Etag"] ~= req_h["If-None-Match"] then
            return false
        end
    end

    return true
end


function set_response(self, res, name)
    local name = name or "response"
    self:ctx()[name] = res
end


function get_response(self, name)
    local name = name or "response"
    return self:ctx()[name]
end


function cache_key(self)
    if not self.ctx().cache_key then
        -- Generate the cache key. The default spec is:
        -- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
        local key_spec = self:config_get("cache_key_spec") or {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
            ngx.var.args,
        }
        table.insert(key_spec, 1, "cache_obj")
        table.insert(key_spec, 1, "ledge")
        self:ctx().cache_key = table.concat(key_spec, ":")
    end
    return self:ctx().cache_key
end


-- Set a config parameter
function config_set(self, param, value)
    if ngx.get_phase() == "init" then
        self.config[param] = value
    else
        self:ctx().config[param] = value
    end
end


-- Gets a config parameter.
function config_get(self, param)
    local p = self:ctx().config[param]
    if p == nil then
        return self.config[param]
    else
        return p
    end
end


function bind(self, event, callback)
    local events = self:ctx().events
    if not events[event] then events[event] = {} end
    table.insert(events[event], callback)
end


function emit(self, event, res)
    local events = self:ctx().events
    for _, handler in ipairs(events[event] or {}) do
        if type(handler) == "function" then
            handler(res)
        end
    end
end

-- Header Utility Functions

function header_has_directive(self, header, directive)
    if header then
        -- Just checking the directive appears in the header, e.g. no-cache, private etc.
        return (header:find(directive, 1, true) ~= nil)
    end
    return false
end

function get_header_token(self, header, directive)
    if self:header_has_directive(header, directive) then
        -- Want the string value from a token
        local value = ngx.re.match(header, directive:gsub('-','\\-').."=([^\\d]+)", "io")
        if value ~= nil then
            return value[1]
        end
        return nil
    end
    return nil
end

function get_numeric_header_token(self, header, directive)
    if self:header_has_directive(header, directive) then
        -- Want the numeric value from a token
        local value = ngx.re.match(header, directive:gsub('-','\\-').."=(\\d+)", "io")
        if value ~= nil then
            return tonumber(value[1])
        end
        return 0
    end
    return 0
end

-- STATES ------------------------------------------------------


function ST_INIT(self)
    self:transition("ST_INIT")
    self:redis_connect()

    if self:request_accepts_cache() then
        return self:ST_ACCEPTING_CACHE()
    else
        return self:ST_FETCHING()
    end
end


function ST_ACCEPTING_CACHE(self)
    self:transition("ST_ACCEPTING_CACHE")

    local res = self:read_from_cache()

    if not res then
        -- Never attempt validation if we have no cache to serve.
        self:remove_client_validators()
        return self:ST_FETCHING()
    elseif res.remaining_ttl <= 0 then
        -- Cache Expired
        return self:ST_CACHE_EXPIRED(res)
    elseif res.remaining_ttl - self:get_numeric_header_token(ngx.req.get_headers()['Cache-Control'], 'min-fresh')  <= 0 then
        -- min-fresh makes this expired
        return self:ST_CACHE_EXPIRED(res)
    else
        self:set_response(res)
        return self:ST_USING_CACHE()
    end
end


function ST_CACHE_EXPIRED(self,res)
    self:transition("ST_CACHE_EXPIRED")

    if self:calculate_stale_ttl(res) > 0 then
        -- Return stale content
        self:set_response(res)
        return self:ST_SERVING_STALE()
    end
    -- Fetch from origin
    self:remove_client_validators()
    return self:ST_FETCHING()
end


function ST_SERVING_STALE(self)
    self:transition("ST_SERVING_STALE")

    self:add_warning('110', 'Response is stale')

    if self:config_get('background_revalidate') then
        self:ctx()['bg_thread'] = ngx.thread.spawn(ST_BG_FETCHING, self)
    end

    return self:ST_SERVING()
end


function ST_USING_CACHE(self)
    self:transition("ST_USING_CACHE")

    if self:must_revalidate() then
        if self:can_revalidate_locally() then
            return self:ST_REVALIDATING_LOCALLY()
        else
            return self:ST_REVALIDATING_UPSTREAM()
        end
    else
        return self:ST_SERVING()
    end
end


function ST_REVALIDATING_LOCALLY(self)
    self:transition("ST_REVALIDATING_LOCALLY")

    if self:is_valid_locally() then
        return self:ST_SERVING_NOT_MODIFIED()
    else
        return self:ST_REVALIDATING_UPSTREAM()
    end
end


function ST_REVALIDATING_UPSTREAM(self)
    self:transition("ST_REVALIDATING_UPSTREAM")
    self:add_validators_from_cache()
    return self:ST_FETCHING()
end


function ST_BG_FETCHING(self)
    self:transition("ST_BG_FETCHING")

    if self:header_has_directive(ngx.req.get_headers()['Cache-Control'], 'only-if-cached') then
        return
    end

    self:remove_client_validators()
    local res = self:fetch_from_origin()
    if res.status == ngx.HTTP_NOT_MODIFIED then
        return
    else
        self:set_response(res)
        if res:is_cacheable() then
            return self:ST_SAVING()
        else
            return self:ST_DELETING()
        end
    end
end


function ST_FETCHING(self)
    self:transition("ST_FETCHING")

    if self:header_has_directive(ngx.req.get_headers()['Cache-Control'], 'only-if-cached') then
        ngx.exit(ngx.HTTP_GATEWAY_TIMEOUT)
    end

    local res = self:fetch_from_origin()
    if res.status == ngx.HTTP_NOT_MODIFIED then
        return self:ST_SERVING()
    else
        self:set_response(res)
        if res:is_cacheable() then
            return self:ST_SAVING()
        else
            return self:ST_DELETING()
        end
    end
end


function ST_SAVING(self)
    self:transition("ST_SAVING")
    if ngx.req.get_method() ~= "HEAD" then
        self:save_to_cache(self:get_response())
    end

    -- Do not serve if we are background revalidating
    if self:ctx().state_history['ST_BG_FETCHING'] then
        return
    end
    return self:ST_SERVING()
end


function ST_DELETING(self)
    self:transition("ST_DELETING")
    self:delete_from_cache()

    -- Do not serve if we are background revalidating
    if self:ctx().state_history['ST_BG_FETCHING'] then
        return
    end
    return self:ST_SERVING()
end


function ST_SERVING(self)
    self:transition("ST_SERVING")

    if self:config_get("enable_esi") then
        self:process_esi()
    end

    self:serve()
    self:redis_close()
end


function ST_SERVING_NOT_MODIFIED(self)
    self:transition("ST_SERVING_NOT_MODIFIED")

    self:get_response().status = ngx.HTTP_NOT_MODIFIED
    return self:ST_SERVING()
end


function ST_PURGING(self)
    self:transition("ST_PURGING")

    self:redis_connect()
    local status_code = ngx.HTTP_OK
    if self:delete_from_cache() == 0 then
        status_code = ngx.HTTP_NOT_FOUND
    end
    self:redis_close()
    ngx.exit(status_code)
end


-- ACTIONS ---------------------------------------------------------


function read_from_cache(self)
    local res = response:new()

    -- Fetch from Redis
    local cache_parts, err = self:ctx().redis:hgetall(cache_key(self))
    if not cache_parts then
        ngx.log(ngx.ERR, "Failed to read cache item: " .. err)
    end

    -- No cache entry for this key
    if #cache_parts == 0 then
        return nil
    end

    local ttl = nil
    local time_in_cache = 0
    local time_since_generated = 0

    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, #cache_parts, 2 do
        -- Look for the "known" fields
        if cache_parts[i] == "body" then
            res.body = cache_parts[i + 1]
        elseif cache_parts[i] == "uri" then
            res.uri = cache_parts[i + 1]
        elseif cache_parts[i] == "status" then
            res.status = tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "expires" then
            res.remaining_ttl = tonumber(cache_parts[i + 1]) - ngx.time()
        elseif cache_parts[i] == "saved_ts" then
            time_in_cache = ngx.time() - tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "generated_ts" then
            time_since_generated = ngx.time() - tonumber(cache_parts[i + 1])
        elseif cache_parts[i] == "esi_comment" then
            res.esi.has_esi_comment = not not cache_parts[i + 1]
        elseif cache_parts[i] == "esi_remove" then
            res.esi.has_esi_remove = not not cache_parts[i + 1]
        elseif cache_parts[i] == "esi_include" then
            res.esi.has_esi_include = not not cache_parts[i + 1]
        else
            -- Unknown fields will be headers, starting with "h:" prefix.
            local header = cache_parts[i]:sub(3)
            if header then
                res.header[header] = cache_parts[i + 1]
            end
        end
    end

    -- Calculate the Age header
    if res.header["Age"] then
        -- We have end-to-end Age headers, add our time_in_cache.
        res.header["Age"] = tonumber(res.header["Age"]) + time_in_cache
    elseif res.header["Date"] then
        -- We have no advertised Age, use the generated timestamp.
        res.header["Age"] = time_since_generated
    end

    self:emit("cache_accessed", res)

    return res
end


function remove_client_validators(self)
    ngx.req.set_header("If-Modified-Since", nil)
    ngx.req.set_header("If-None-Match", nil)
end


function add_validators_from_cache(self)
    local cached_res = self:get_response()

    -- TODO: Patch OpenResty to accept additional headers for subrequests.
    ngx.req.set_header("If-Modified-Since", cached_res.header["Last-Modified"])
    ngx.req.set_header("If-None-Match", cached_res.header["Etag"])
end


-- Fetches a resource from the origin server.
function fetch_from_origin(self)
    local res = response:new()
    self:emit("origin_required")

    -- If we're in BYPASS mode, we can't fetch anything.
    if self:config_get("origin_mode") == ORIGIN_MODE_BYPASS then
        res.status = ngx.HTTP_SERVICE_UNAVAILABLE
        return res
    end

    local method = ngx['HTTP_' .. ngx.req.get_method()]
    -- Unrecognised request method, do not proxy
    if not method then
        res.status = ngx.HTTP_METHOD_NOT_IMPLEMENTED
        return res
    end

    local origin = ngx.location.capture(self:config_get("origin_location")..relative_uri(), {
        method = method,
        body = ngx.req.get_body_data(),
    })

    res.status = origin.status
    -- Merge headers in rather than wipe out the res.headers table)
    for k,v in pairs(origin.header) do
        res.header[k] = v
    end
    res.body = origin.body

    if res.status < 500 then
        -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.18
        -- A received message that does not have a Date header field MUST be assigned
        -- one by the recipient if the message will be cached by that recipient
        if not res.header["Date"] or not ngx.parse_http_time(res.header["Date"]) then
            ngx.log(ngx.WARN, "no Date header from upstream, generating locally")
            res.header["Date"] = ngx.http_time(ngx.time())
        end
    end

    -- A nice opportunity for post-fetch / pre-save work.
    self:emit("origin_fetched", res)

    return res
end


function save_to_cache(self, res)
    self:emit("before_save", res)

    -- These "hop-by-hop" response headers MUST NOT be cached:
    -- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
    local uncacheable_headers = {
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailers",
        "Transfer-Encoding",
        "Upgrade",

        -- We also choose not to cache the content length, it is set by Nginx
        -- based on the response body.
        "Content-Length",
    }

    -- Also don't cache any headers marked as Cache-Control: (no-cache|no-store|private)="header".
    if res.header["Cache-Control"] and res.header["Cache-Control"]:find("=") then
        local patterns = { "no%-cache", "no%-store", "private" }
        for _,p in ipairs(patterns) do
            for h in res.header["Cache-Control"]:gmatch(p .. "=\"?([%a-]+)\"?") do
                table.insert(uncacheable_headers, h)
            end
        end
    end

    -- Utility to search in uncacheable_headers.
    local function is_uncacheable(t, h)
        for _, v in ipairs(t) do
            if v:lower() == h:lower() then
                return true
            end
        end
        return nil
    end

    -- Turn the headers into a flat list of pairs for the Redis query.
    local h = {}
    for header,header_value in pairs(res.header) do
        if not is_uncacheable(uncacheable_headers, header) then
            table.insert(h, 'h:'..header)
            table.insert(h, header_value)
        end
    end

    local redis = self:ctx().redis

    -- Save atomically
    redis:multi()

    -- Delete any existing data, to avoid accidental hash merges.
    redis:del(cache_key(self))

    local ttl = res:ttl()
    local expires = ttl + ngx.time()
    local uri = full_uri()

    redis:hmset(cache_key(self),
        'body', res.body,
        'status', res.status,
        'uri', uri,
        'expires', expires,
        'generated_ts', ngx.parse_http_time(res.header["Date"]),
        'saved_ts', ngx.time(),
        unpack(h)
    )

    -- If ESI is enabled, store detected ESI features on the slow path.
    if self:config_get("enable_esi") == true then
        redis:hmset(cache_key(self),
            'esi_comment', tostring(res:has_esi_comment()),
            'esi_remove', tostring(res:has_esi_remove()),
            'esi_include', tostring(res:has_esi_include())
        )
    end

    redis:expire(cache_key(self), ttl + tonumber(self:config_get("keep_cache_for")))

    -- Add this to the uris_by_expiry sorted set, for cache priming and analysis
    redis:zadd('ledge:uris_by_expiry', expires, uri)

    -- Run transaction
    local replies, err = redis:exec()
    if not replies then
        ngx.log(ngx.ERR, "Failed to save cache item: " .. err)
    end
end


function delete_from_cache(self)
    return self:ctx().redis:del(self:cache_key())
end


function serve(self)
    if not ngx.headers_sent then
        local res = self:get_response()
        assert(res.status, "Response has no status.")

        -- Via header
        local via = "1.1 " .. visible_hostname() .. " (ledge/" .. _VERSION .. ")"
        if  (res.header["Via"] ~= nil) then
            res.header["Via"] = via .. ", " .. res.header["Via"]
        else
            res.header["Via"] = via
        end

        -- X-Cache header
        -- Don't set if this isn't a cacheable response (ST_DELETING). Set to MISS is
        -- we went through ST_FETCHING, otherwise HIT.
        local st_hist = self:ctx().state_history
        if not st_hist["ST_DELETING"] then
            local x_cache = "HIT from " .. ngx.var.hostname
            if st_hist["ST_FETCHING"] then
                x_cache = "MISS from " .. ngx.var.hostname
            end

            if res.header["X-Cache"] ~= nil then
                res.header["X-Cache"] = x_cache .. ", " .. res.header["X-Cache"]
            else
                res.header["X-Cache"] = x_cache
            end
        end

        self:emit("response_ready", res)

        -- If we have a 5xx or a 3/4xx and no body entity, exit allowing nginx config
        -- to generate a response.
        if res.status >= 500 or (res.status >= 300 and res.body == nil) then
            ngx.exit(res.status)
        end

        -- Otherwise send the response as normal.
        ngx.status = res.status

        if res.header then
            for k,v in pairs(res.header) do
                ngx.header[k] = v
            end
        end

        if res.body then
            ngx.print(res.body)
        end

        ngx.eof()
    end
end


function add_warning(self, code, text)
    local res = self:get_response()
    if not res.header["Warning"] then
        res.header["Warning"] = {}
    end

    local header = code .. ' ' .. visible_hostname() .. ' "' .. text .. '"'
    table.insert(res.header["Warning"], header)
end


function process_esi(self)
    local res = self:get_response()
    local body = res.body
    local transformed = false

    -- Only perform trasnformations if we know there's work to do. This is determined
    -- during fetch (slow path).

    if res:has_esi_comment() then
        body = ngx.re.gsub(body, "(<!--esi(.*?)-->)", "$2", "soj")
        transformed = true
    end

    if res:has_esi_remove() then
        body = ngx.re.gsub(body, "(<esi:remove>.*?</esi:remove>)", "", "soj")
        transformed = true
    end

    if res:has_esi_include() then
        local esi_uris = {}
        for tag in ngx.re.gmatch(body, "<esi:include src=\"(.+)\".*/>", "oj") do
            table.insert(esi_uris, { tag[1] })
        end

        if table.getn(esi_uris) > 0 then
            -- Only works for relative URIs right now
            -- TODO: Extract hostname from absolute uris, and set the Host header accordingly.
            local esi_fragments = { ngx.location.capture_multi(esi_uris) }

            -- Create response objects.
            for i,fragment in ipairs(esi_fragments) do
                esi_fragments[i] = response:new(fragment)
            end

            -- Ensure that our cacheability is reduced shortest / newest from
            -- all fragments.
            res:minimise_lifetime(esi_fragments)

            body = ngx.re.gsub(body, "(<esi:include.*/>)", function(tag)
                return table.remove(esi_fragments, 1).body
            end, "ioj")
        end
        transformed = true
    end

    if transformed then
        if res.header["Content-Length"] then res.header["Content-Length"] = #body end
        res.body = body

        self:add_warning(214, "Transformation applied")
        self:set_response(res)
    end
end


local class_mt = {
    -- to prevent use of casual module global variables
    __newindex = function (table, key, val)
        error('attempt to write to undeclared variable "' .. key .. '"')
    end
}


setmetatable(_M, class_mt)
