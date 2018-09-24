local http_headers = require "resty.http_headers"
local util = require "ledge.util"

local pairs, setmetatable, tonumber, unpack =
    pairs, setmetatable, tonumber, unpack

local tbl_getn = table.getn
local tbl_insert = table.insert
local tbl_concat = table.concat
local tbl_sort   = table.sort

local str_lower = string.lower
local str_find = string.find
local str_sub = string.sub
local str_rep = string.rep
local str_randomhex = util.string.randomhex
local str_split = util.string.split

local ngx_null = ngx.null
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local ngx_DEBUG = ngx.DEBUG
local ngx_re_gmatch = ngx.re.gmatch
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_re_find = ngx.re.find
local ngx_re_gsub = ngx.re.gsub

local header_has_directive = require("ledge.header_util").header_has_directive

local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy

local save_key_chain = require("ledge.cache_key").save_key_chain

local _DEBUG = false

local _M = {
    _VERSION = "2.1.3",
    set_debug = function(debug) _DEBUG = debug end,
}


-- Body reader for when the response body is missing
local function empty_body_reader()
    return nil
end
_M.empty_body_reader = empty_body_reader


function _M.new(handler)
    if not handler or not next(handler) then
        return nil, "Handler is required"
    end

    if not handler.redis or not next(handler.redis) then
        return nil, "Handler has no redis connection"
    end

    return setmetatable({
        redis = handler.redis,
        handler = handler,  -- Cache key chain

        uri = "",
        status = 0,
        header = http_headers.new(),

        -- stored metadata
        size = 0,
        remaining_ttl = 0,
        has_esi = false,
        esi_scanned = false,

        -- body
        entity_id = "",
        body_reader = empty_body_reader,
        body_filters = {}, -- for debug logging

        -- runtime metadata (not persisted)
        length = 0,  -- If Content-Length is present
        has_body = false,  -- From lua-resty-http has_body

    }, get_fixed_field_metatable_proxy(_M))
end


-- Setter for a fixed body string (not streamed)
function _M.set_body(self, body_string)
    local sent = false
    self.body_reader = function()
        if not sent then
            sent = true
            return body_string
        else
            return nil
        end
    end
end


function _M.filter_body_reader(self, filter_name, filter)
    assert(type(filter) == "function", "filter must be a function")

    if _DEBUG then
        -- Keep track of the filters by name, just for debugging
        ngx_log(ngx_DEBUG,
            filter_name,
            "(",
            tbl_concat(self.body_filters,
                "("), "" , str_rep(")", #self.body_filters - 1
            ),
            ")"
        )

        tbl_insert(self.body_filters, 1, filter_name)
    end

    self.body_reader = filter
end


function _M.is_cacheable(self)
    -- Never cache partial content
    local status = self.status
    if status == 206 or status == 416 then
        return false
    end

    local h = self.header
    local directives = "(no-cache|no-store|private)"
    if header_has_directive(h["Cache-Control"], directives, true) then
        return false
    end

    if header_has_directive(h["Pragma"], "no-cache", true) then
        return false
    end

    if h["Vary"] == "*" then
       return false
    end

    if self:ttl() > 0 then
        return true
    else
        return false
    end
end


-- Calculates the TTL from response headers.
-- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM
-- and finally Expires: HTTP_TIMESTRING.
function _M.ttl(self)
    local cc = self.header["Cache-Control"]
    if cc then
        if type(cc) == "table" then
            cc = tbl_concat(cc, ", ")
        end
        local max_ages = {}
        for max_age in ngx_re_gmatch(cc, [[(s-maxage|max-age)=(\d+)]], "ijo") do
            max_ages[max_age[1]] = max_age[2]
        end

        if max_ages["s-maxage"] then
            return tonumber(max_ages["s-maxage"])
        elseif max_ages["max-age"] then
            return tonumber(max_ages["max-age"])
        end
    end

    -- Fall back to Expires.
    local expires = self.header["Expires"]
    if expires then
        -- If there are multiple, last one wins
        if type(expires) == "table" then
            expires = expires[#expires]
        end

        local time = ngx_parse_http_time(tostring(expires))
        if time then return time - ngx_time() end
    end

    return 0
end


function _M.has_expired(self)
    return self.remaining_ttl <= 0
end


-- Return nil and an error on an actual Redis error, this indicates that Redis
-- has failed and we aren't going to be able to proceed normally.
-- Return nil and *no* error if this is just a broken/partial cache entry
-- so we MISS and update the entry.
function _M.read(self)
    local key_chain, err = self.handler:cache_key_chain()
    if not key_chain then
        return nil, err
    end

    local redis = self.redis

    -- Read main metdata
    local cache_parts, err = redis:hgetall(key_chain.main)
    if not cache_parts or cache_parts == ngx_null then
        return nil, err
    end

    -- No cache entry for this key
    local cache_parts_len = #cache_parts
    if not cache_parts_len or cache_parts_len == 0 then
        return nil
    end

    local time_in_cache = 0
    local time_since_generated = 0

    -- The Redis replies is a sequence of messages, so we iterate over pairs
    -- to get hash key/values.
    for i = 1, cache_parts_len, 2 do
        if cache_parts[i] == "uri" then
            self.uri = cache_parts[i + 1]

        elseif cache_parts[i] == "status" then
            self.status = tonumber(cache_parts[i + 1])

        elseif cache_parts[i] == "entity" then
            self.entity_id = cache_parts[i + 1]

        elseif cache_parts[i] == "expires" then
            self.remaining_ttl = tonumber(cache_parts[i + 1]) - ngx_time()

        elseif cache_parts[i] == "saved_ts" then
            time_in_cache = ngx_time() - tonumber(cache_parts[i + 1])

        elseif cache_parts[i] == "generated_ts" then
            time_since_generated = ngx_time() - tonumber(cache_parts[i + 1])

        elseif cache_parts[i] == "has_esi" then
           self.has_esi = cache_parts[i + 1]

        elseif cache_parts[i] == "esi_scanned" then
            local scanned = cache_parts[i + 1]
            if scanned == "false" then
                self.esi_scanned = false
            else
                self.esi_scanned = true
            end

        elseif cache_parts[i] == "size" then
            self.size = tonumber(cache_parts[i + 1])
        end
    end

    -- Read headers
    local headers, err = redis:hgetall(key_chain.headers)
    if not headers or headers == ngx_null then
        return nil, err
    end

    local headers_len = tbl_getn(headers)
    if headers_len == 0 then
        ngx_log(ngx_INFO, "headers missing")
        return nil
    end

    for i = 1, headers_len, 2 do
        local header = headers[i]
        if str_find(header, ":") then
            -- We have multiple headers with the same field name
            local _, key = unpack(str_split(header, ":"))
            if not self.header[key] then
                self.header[key] = {}
            end
            tbl_insert(self.header[key], headers[i + 1])
        else
            self.header[header] = headers[i + 1]
        end
    end

    -- Calculate the Age header
    if self.header["Age"] then
        -- We have end-to-end Age headers, add our time_in_cache.
        self.header["Age"] = tonumber(self.header["Age"]) + time_in_cache
    elseif self.header["Date"] then
        -- We have no advertised Age, use the generated timestamp.
        self.header["Age"] = time_since_generated
    end

    -- "touch" other keys not needed for read, so that they are
    -- less likely to be unfairly evicted ahead of time
    -- Note: From Redis 3.2.1 this could be one TOUCH command
    local _ = redis:hlen(key_chain.reval_params)
    local _ = redis:hlen(key_chain.reval_req_headers)
    if self.size > 0 then
        local entities, err = redis:scard(key_chain.entities)
        if not entities or entities == ngx_null then
            return nil, "could not read entities set: " .. err
        elseif entities == 0 then
            ngx_log(ngx_INFO, "entities set is empty")
            return nil
        end
    end

    -- Check this key is in the repset
    local scard, err = redis:sismember(key_chain.repset, key_chain.full)
    if err then
        return nil, err
    end

    -- Got a cache entry but missing from repset or repset missing, bad...
    -- Call save_key_chain which will add this rep to the repset
    if scard == 0 then
        local repset_ttl = redis:ttl(key_chain.main)
        local ok, err = save_key_chain(redis, key_chain, repset_ttl)
        if not ok then
            return nil, err
        end
    end

    return true
end


-- Takes headers from a HTTP response and returns a flat table of cacheable
-- header entries formatted for Redis.
local function prepare_cacheable_headers(headers)
    -- Don't cache any headers marked as
    -- Cache-Control: (no-cache|no-store|private)="header".
    local uncacheable_headers = {}
    local cc = headers["Cache-Control"]
    if cc then
        if type(cc) == "table" then cc = tbl_concat(cc, ", ") end
        cc = str_lower(cc)
        if str_find(cc, "=", 1, true) then
            local pattern = '(?:no-cache|private)="?([0-9a-z-]+)"?'
            local re_ctx = {}
            repeat
                local from, to, err = ngx_re_find(cc, pattern, "jo", re_ctx, 1)
                if from then
                    uncacheable_headers[str_sub(cc, from, to)] = true
                elseif err then
                    ngx_log(ngx_ERR, err)
                end
            until not from
        end
    end

    -- Turn the headers into a flat list of pairs for the Redis query.
    local h = {}
    for header,header_value in pairs(headers) do
        if not uncacheable_headers[str_lower(header)] then
            if type(header_value) == 'table' then
                -- Multiple headers are represented as a table of values
                local header_value_len = tbl_getn(header_value)
                for i = 1, header_value_len do
                    tbl_insert(h, i..':'..header)
                    tbl_insert(h, header_value[i])
                end
            else
                tbl_insert(h, header)
                tbl_insert(h, header_value)
            end
        end
    end

    return h
end


function _M.save(self, keep_cache_for)
    if not keep_cache_for then keep_cache_for = 0 end

    -- Create a new entity id
    self.entity_id = str_randomhex(32)

    local ttl = self:ttl()
    local time = ngx_time()

    local redis = self.redis
    if not next(redis) then return nil, "no redis" end
    local key_chain = self.handler:cache_key_chain()

    if not self.header["Date"] then
        self.header["Date"] = ngx_http_time(ngx_time())
    end

    local ok, err = redis:del(key_chain.main)
    if not ok then ngx_log(ngx_ERR, err) end

    local ok, err = redis:hmset(key_chain.main,
        "entity",       self.entity_id,
        "status",       self.status,
        "uri",          self.uri,
        "expires",      ttl + time,
        "generated_ts", ngx_parse_http_time(self.header["Date"]),
        "saved_ts",     time,
        "esi_scanned",  tostring(self.esi_scanned)  -- from bool
    )
    if not ok then ngx_log(ngx_ERR, err) end

    local h = prepare_cacheable_headers(self.header)

    ok, err = redis:del(key_chain.headers)
    if not ok then ngx_log(ngx_ERR, err) end

    ok, err = redis:hmset(key_chain.headers, unpack(h))
    if not ok then ngx_log(ngx_ERR, err) end

    -- Mark the keys as eventually volatile (the body is set by the body writer)
    local expiry = ttl + tonumber(keep_cache_for)

    ok, err = redis:expire(key_chain.main, expiry)
    if not ok then ngx_log(ngx_ERR, err) end

    ok, err = redis:expire(key_chain.headers, expiry)
    if not ok then ngx_log(ngx_ERR, err) end

    local ok, err = redis:sadd(key_chain.entities, self.entity_id)
    if not ok then
        ngx_log(ngx_ERR, "error adding entity to set: ", err)
    end

    ok, err = redis:expire(key_chain.entities, expiry)
    if not ok then ngx_log(ngx_ERR, err) end

    return true
end


function _M.set_and_save(self, field, value)
    local redis = self.redis

    local ok, err = redis:hset(self.handler:cache_key_chain().main, field, tostring(value))
    if not ok then
        if err then ngx_log(ngx_ERR, err) end
        return nil, err
    end

    self[field] = value
    return ok
end


local WARNINGS = {
    ["110"] = "Response is stale",
    ["214"] = "Transformation applied",
    ["112"] = "Disconnected Operation",
}


function _M.add_warning(self, code, name)
    if not self.header["Warning"] then
        self.header["Warning"] = {}
    end

    local header = code .. ' ' .. name
    header = header .. ' "' .. WARNINGS[code] .. '"'
    tbl_insert(self.header["Warning"], header)
end


local function deduplicate_table(table)
    -- Can't have duplicates if there's 1 or 0 entries!
    if #table <= 1 then
        return table
    end

    local new_table = {}
    local unique = {}
    local i = 0

    for _,v in ipairs(table) do
        if not unique[v] then
            unique[v] = true
            i = i +1
            new_table[i] = v
        end
    end

    return new_table
end


function _M.parse_vary_header(self)
    local vary_hdr = self.header["Vary"]
    local vary_spec

    if vary_hdr and vary_hdr ~= "" then
        if type(vary_hdr) == "table" then
            vary_hdr = tbl_concat(vary_hdr,",")
        end
        -- Remove whitespace around commas and lowercase
        vary_hdr = ngx_re_gsub(str_lower(vary_hdr), [[\s*,\s*]], ",", "oj")
        vary_spec = str_split(vary_hdr, ",")
        tbl_sort(vary_spec)
        vary_spec = deduplicate_table(vary_spec)
    end

    -- Return the new vary sepc table *and* the normalised header
    return vary_spec
end


return _M
