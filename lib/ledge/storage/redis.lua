local redis = require "resty.redis"
local redis_connector = require "resty.redis.connector"

local   tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable =
        tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable

local ngx_null = ngx.null
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_NOTICE = ngx.NOTICE
local ngx_WARN = ngx.WARN

local tbl_insert = table.insert
local tbl_copy = require("ledge.util").table.copy
local tbl_copy_merge_defaults = require("ledge.util").table.copy_merge_defaults
local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable
local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _M = {
    _VERSION = '1.28.3',
}


-- Default parameters
local defaults = setmetatable({
    redis_connector_params = {},

    max_size = 1024 * 1024,  -- Max storable size, in bytes

    -- Optional atomicity
    -- e.g. for use with a Redis proxy which doesn't support transactions
    supports_transactions = true,
}, fixed_field_metatable)


-- Redis key namespace
local KEY_PREFIX = "ledge:entity:"


-- Returns the Redis keys for entity_id
local function entity_keys(entity_id)
    if entity_id then
        return {
            -- Both keys are lists of chunks
            body        = KEY_PREFIX .. "{" .. entity_id .. "}" .. ":body",
            body_esi    = KEY_PREFIX .. "{" .. entity_id .. "}" .. ":body_esi",
        }
    end
end


-- Creates a new (disconnected) storage instance
--
-- @return  table   The module instance
function _M.new()
    return setmetatable({
        redis = {},
        params = {},

        _reader_cursor = 0,
        _keys_created = false,
    }, get_fixed_field_metatable_proxy(_M))
end


-- Connects to the Redis storage backend
--
-- @param   table   Module instance (self)
-- @param   table   Storage params
function _M.connect(self, user_params)
    -- take user_params by value and merge with defaults
    user_params = tbl_copy_merge_defaults(user_params, defaults)
    self.params = user_params

    local redis, err = redis_connector.new(
        user_params.redis_connector_params
    ):connect()

    if not redis then
        return nil, err
    else
        self.redis = redis
        return self, nil
    end
end


-- Closes the Redis connection (placing back on the keepalive pool)
--
-- @param   table   Module instance (self)
function _M.close(self)
    self._reader_cursor = 0
    self._keys_created = false

    local redis = self.redis
    if redis then
        return redis_connector.new(
            self.params.redis_connector_params
        ):set_keepalive(redis)
    end
end


-- Returns the maximum size this connection is prepared to store.
--
-- @param   table   Module instance (self)
-- @return  number  Size (bytes)
function _M.get_max_size(self)
    return self.params.max_size
end


-- Returns a boolean indicating if the entity exists.
--
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  boolean (exists)
-- @return  string  err (or nil)
function _M.exists(self, entity_id)
    local keys = entity_keys(entity_id)
    if not keys then
        return nil, "no entity id"
    else
        local redis = self.redis

        redis:init_pipeline(2)
        redis:exists(keys.body)
        redis:exists(keys.body_esi)
        local res, err = redis:commit_pipeline()

        if not res and err then
            return nil, err
        elseif res == ngx_null or #res < 2 then
            return nil, "expected 2 pipelined command results"
        else
            return res[1] == 1 and res[2] == 1
        end
    end
end


-- Deletes an entity
--
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  boolean success
-- @return  string  err (or nil)
function _M.delete(self, entity_id)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        local keys = {}
        for k, v in pairs(key_chain) do
            tbl_insert(keys, v)
        end
        local res, err = self.redis:del(unpack(keys))
        if res == 0 and not err then
            return false, nil
        else
            return res, err
        end
    end
end


-- Sets the time-to-live for an entity
--
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @param   number  TTL (seconds)
-- @return  boolean success
-- @return  string  err (or nil)
function _M.set_ttl(self, entity_id, ttl)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        local res, err
        for _,key in pairs(key_chain) do
            res, err = self.redis:expire(key, ttl)
        end
        if not res then
            return res, err
        elseif res == 0 then
            return false, "entity does not exist"
        else
            return true, nil
        end
    end
end


-- Gets the time-to-live for an entity
--
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  number  ttl
-- @return  string  err (or nil)
function _M.get_ttl(self, entity_id)
    local key_chain = entity_keys(entity_id)
    if next(key_chain) then
        local res, err = self.redis:ttl(key_chain.body)
        if not res then
            return res, err
        elseif res == -2 then
            return false, "entity does not exist"
        elseif res == -1 then
            return false, "entity does not have a ttl"
        else
            return res, nil
        end
    end
end


-- Returns an iterator for reading the body chunks.
--
-- @param   table       Module instance (self)
-- @param   table       Response object
-- @return  function    Iterator, returning chunk, err, has_esi for each call
function _M.get_reader(self, res)
    local redis = self.redis
    local entity_id = res.entity_id
    local entity_keys = entity_keys(entity_id)
    local num_chunks = redis:llen(entity_keys.body) or 0

    return function()
        local cursor = self._reader_cursor
        self._reader_cursor = cursor + 1

        if cursor < num_chunks then
            local chunk, err = redis:lindex(entity_keys.body, cursor)
            if not chunk then return nil, err, nil end

            local has_esi, err = redis:lindex(entity_keys.body_esi, cursor)
            if not has_esi then return nil, err, nil end

            if chunk == ngx_null or has_esi == ngx_null then
                ngx_log(ngx_WARN,
                    "entity removed during read, ",
                    entity_keys.body
                )
            end

            return chunk, nil, has_esi == "true"
        end
    end
end


-- Writes a given chunk
local function write_chunk(self, entity_keys, chunk, has_esi, ttl)
    local redis = self.redis

    -- Write chunks / has_esi onto lists
    local ok, e = redis:rpush(entity_keys.body, chunk)
    if not ok then return nil, e end

    ok, e = redis:rpush(entity_keys.body_esi, tostring(has_esi))
    if not ok then return nil, e end

    -- If this is the first write, set expiration too
    if not self._keys_created then
        self._keys_created = true

        ok, e = redis:expire(entity_keys.body, ttl)
        if not ok then return nil, e end

        ok, e = redis:expire(entity_keys.body_esi, ttl)
        if not ok then return nil, e end
    end

    return true, nil
end


-- Returns an iterator which writes chunks to cache as they are read from
-- reader belonging to the repsonse object.
-- If we cross the maxsize boundary, or error for any reason, we just
-- keep yielding chunks to be served, after having removed the cache entry.
--
-- @param   table       Module instance (self)
-- @param   table       Response object
-- @param   number      time-to-live
-- @param   function    onsuccess callback
-- @param   function    onfailure callback
-- @return  function    Iterator, returning chunk, err, has_esi for each call
function _M.get_writer(self, res, ttl, onsuccess, onfailure)
    local redis = self.redis
    local max_size = self.params.max_size
    local supports_transactions = self.params.supports_transactions

    local entity_id = res.entity_id
    local entity_keys = entity_keys(entity_id)

    local failed = false
    local failed_reason = ""
    local transaction_open = false

    local size = 0
    local reader = res.body_reader

    return function(buffer_size)
        if not transaction_open and supports_transactions then
            redis:multi()
            transaction_open = true
        end

        local chunk, err, has_esi = reader(buffer_size)

        if chunk and not failed then  -- We have something to write
            size = size + #chunk

            if max_size and size > max_size then
                failed = true
                failed_reason = "body is larger than " .. max_size .. " bytes"
            else
                local ok, e = write_chunk(self,
                    entity_keys,
                    chunk,
                    has_esi,
                    ttl
                )
                if not ok then
                    failed = true
                    failed_reason = "error writing: " .. tostring(e)
                end
            end

        elseif not chunk and not failed then  -- We're finished
            if supports_transactions then
                local ok, e = redis:exec() -- Commit

                if not ok or ok == ngx_null then
                    -- Transaction failed
                    ok, e = pcall(onfailure, e)
                    if not ok then ngx_log(ngx_ERR, e) end
                end
            end

            -- All good, report success
            local ok, e = pcall(onsuccess, size)
            if not ok then ngx_log(ngx_ERR, e) end

        elseif not chunk and failed then  -- We're finished, but failed
            if supports_transactions then
                redis:discard() -- Rollback
            else
                -- Attempt to clean up manually (connection could be dead)
                local ok, e = redis:del(
                    entity_keys.body,
                    entity_keys.body_esi
                )
                if not ok or ok == ngx_null then ngx_log(ngx_ERR, e) end
            end

            local ok, e = pcall(onfailure, failed_reason)
            if not ok then ngx_log(ngx_ERR, e) end
        end

        -- Always bubble up
        return chunk, err, has_esi
    end
end


return _M
