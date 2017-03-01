local h_util = require "ledge.header_util"
local util = require "ledge.util"
local http_headers = require "resty.http_headers"

local pairs, ipairs, setmetatable, tonumber, unpack =
    pairs, ipairs, setmetatable, tonumber, unpack

local tbl_concat = table.concat
local str_lower = string.lower
local str_gsub = string.gsub
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_match = ngx.re.match
local ngx_parse_http_time = ngx.parse_http_time
local ngx_http_time = ngx.http_time
local ngx_time = ngx.time
local ngx_req_get_headers = ngx.req.get_headers
local tbl_getn = table.getn
local tbl_insert = table.insert
local str_find = string.find
local str_split = string.split



local _M = {
    _VERSION = '1.28.3'
}

local NOCACHE_HEADERS = {
    ["Pragma"] = { "no-cache" },
    ["Cache-Control"] = {
        "no-cache",
        "no-store",
        "private",
    }
}


-- Const functions
local _empty_body_reader = function() return nil end

local _newindex = function(t, k, v)
    -- error if object is modified externally
    error("Attempt to modify response object", 2)
end


local _M = {
    _VERSION = '1.28'
}

local mt = {
    __index = _M,
    __newindex = _newindex,
    __metatable = false,
}


function _M.new(ctx)
    return setmetatable({
        ctx = ctx,  -- Request context
        conn = {},  -- httpc instance

        uri = "",
        status = 0,
        header = http_headers.new(),

        -- stored metadata
        remaining_ttl = 0,
        has_esi = false,
        size = 0,

        -- runtime metadata
        esi_scanned = false,
        length = 0,  -- If Content-Length is present

        -- body
        has_body = false,
        entity_id = "",
        body_reader = _empty_body_reader,
    }, mt)
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


function _M.is_cacheable(self)
    -- Never cache partial content
    local status = self.status
    if status == 206 or status == 416 then
        return false
    end

    for k,v in pairs(NOCACHE_HEADERS) do
        for i,h in ipairs(v) do
            if self.header[k] and self.header[k] == h then
                return false
            end
        end
    end

    if self:ttl() > 0 then
        return true
    else
        return false
    end
end


-- Calculates the TTL from response headers.
-- Header precedence is Cache-Control: s-maxage=NUM, Cache-Control: max-age=NUM,
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


function _M.read(self, key_chain)
    local redis = self.ctx.redis

    -- Read main metdata
    local cache_parts, err = redis:hgetall(key_chain.main)
    if not cache_parts then
        if err then
            return nil, err -- self:e "http_internal_server_error"
        else
            return nil
        end
    end

    -- No cache entry for this key
    local cache_parts_len = #cache_parts
    if not cache_parts_len then
        ngx_log(ngx_ERR, "live entity has no data")
        return nil
    end

    -- "touch" other keys not needed for read, so that they are
    -- less likely to be unfairly evicted ahead of time
    -- TODO: From Redis 3.2.1 this can be one TOUCH command
    local _ = redis:hlen(key_chain.reval_params)
    local _ = redis:hlen(key_chain.reval_req_headers)
    local entities, err = redis:scard(key_chain.entities)
    if not entities or entities == ngx_null then
        ngx_log(ngx_ERR, "could not read entities set: ", err)
        return nil
    elseif entities == 0 then
        -- Entities set is perhaps evicted
        return nil
    end

    local ttl = nil
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
      --  elseif cache_parts[i] == "has_esi" then
         --   self.has_esi = cache_parts[i + 1]
         --
        elseif cache_parts[i] == "esi_scanned" then
            local scanned = cache_parts[i + 1]
            if scanned == "false" then
                self.esi_scanned = false
            else
                self.esi_scanned = true
            end

        --elseif cache_parts[i] == "size" then
          --  self.size = tonumber(cache_parts[i + 1])
        end
    end

    -- Read headers
    local headers = redis:hgetall(key_chain.headers)
    if not headers or headers == ngx_null then
        ngx_log(ngx_ERR, "could not read headers: ", err)
        return nil
    end

    local headers_len = tbl_getn(headers)
    if headers_len == 0 then
        -- Headers have likely been evicted
        return nil
    end

    for i = 1, headers_len, 2 do
        local header = headers[i]
        if str_find(header, ":") then
            -- We have multiple headers with the same field name
            local index, key = unpack(str_split(header, ":"))
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

    return true
end


function _M.save(self)

end


return _M
