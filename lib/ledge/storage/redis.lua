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


local _M = {
    _VERSION = '1.28.3',
}

local mt = {
    __index = _M,
    __newindex = function() error("attempt to create new module field", 2) end,
    __metatable = false,
}


-- Default parameters
local defaults = {
    connect_timeout = 500,
    read_timeout = 5000,
    connection_options = {},
    keepalive_timeout = 60000,
    keepalive_poolsize = 30,

    -- lua-resty-redis-connector params
    redis_connector = {
        url = "redis://127.0.0.1:6379/0", -- Default Redis params
    },

    max_size = 1024 * 1024,  -- Max storable size, in bytes

    -- Optional atomicity
    -- e.g. for use with a Redis proxy which doesn't support transactions
    supports_transactions = true,
}


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


--------------------------------------------------------------------------------
-- Creates a new (disconnected) storage instance
--------------------------------------------------------------------------------
-- @param   table   The request context
-- @return  table   The module instance
--------------------------------------------------------------------------------
function _M.new(ctx)
    return setmetatable({
        ctx = ctx, -- TODO: Make this go away
        redis = {},
        params = {},

        _reader_cursor = 0,
        _keys_created = false,
    }, mt)
end


--------------------------------------------------------------------------------
-- Connects to the Redis storage backend
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @param   table   Storage params
--------------------------------------------------------------------------------
function _M.connect(self, params)
    -- Apply defaults to params
    self.params = setmetatable(params, {
        __index = defaults,
        __newindex = function() error("attempt to create param field", 2) end,
    })

    local rc = redis_connector.new()
    rc:set_connect_timeout(params.connect_timeout)
    rc:set_read_timeout(params.read_timeout)
    rc:set_connection_options(params.connection_options)

    -- Connect
    local redis, err = rc:connect({ redis_connector = params.redis_connector })
    if not redis then
        return nil, err
    else
        self.redis = redis
        return redis, nil
    end
end


--------------------------------------------------------------------------------
-- Closes the Redis connection (placing back on the keepalive pool)
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
--------------------------------------------------------------------------------
function _M.close(self)
    self._reader_cursor = 0
    self._keys_created = false

    local redis = self.redis
    if redis then
        local params = self.params
        if params.supports_transactions then
            -- Restore the connection to "NORMAL" before placing in the
            -- keepalive pool
            redis:discard()
        end

        local ok, err = redis:set_keepalive(
            params.keepalive_timeout,
            params.keepalive_pool_size
        )

        if not ok then
            ngx_log(ngx_WARN, "couldn't set keepalive,, ", err)
            return redis:close()
        end

        return ok
    end
end


--------------------------------------------------------------------------------
-- Returns the maximum size this connection is prepared to store.
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @return  number  Size (bytes)
--------------------------------------------------------------------------------
function _M.get_max_size(self)
    return self.params.max_size
end


--------------------------------------------------------------------------------
-- Returns a boolean indicating if the entity exists.
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  boolean (exists)
-- @return  string  err (or nil)
--------------------------------------------------------------------------------
function _M.exists(self, entity_id)
    local keys = entity_keys(entity_id)
    if not keys then
        return nil, "no entity id"
    else
        local redis = self.redis

        local res, err = redis:exists(keys.body, keys.body_esi)
        if not res and err then
            return nil, err
        elseif res == ngx_null or res < 2 then
            return false
        else
            return true, nil
        end
    end
end


--------------------------------------------------------------------------------
-- Deletes an entity
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  boolean success
-- @return  string  err (or nil)
--------------------------------------------------------------------------------
function _M.delete(self, entity_id)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        local keys = {}
        for k, v in pairs(key_chain) do
            tbl_insert(keys, v)
        end
        -- TODO: return bool
        return self.redis:del(unpack(keys))
    end
end


--------------------------------------------------------------------------------
-- Sets the time-to-live for an entity
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @param   number  TTL (seconds)
-- @return  boolean success
-- @return  string  err (or nil)
--------------------------------------------------------------------------------
function _M.set_ttl(self, entity_id, ttl)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        for _,key in pairs(key_chain) do
            -- TODO: Return bool
            self.redis:expire(key, ttl)
        end
    end
end


--------------------------------------------------------------------------------
-- Gets the time-to-live for an entity
--------------------------------------------------------------------------------
-- @param   table   Module instance (self)
-- @param   string  The entity ID
-- @return  number  ttl
-- @return  string  err (or nil)
--------------------------------------------------------------------------------
function _M.get_ttl(self, entity_id)
    -- TODO: implement
end


--------------------------------------------------------------------------------
-- Returns an iterator for reading the body chunks.
--------------------------------------------------------------------------------
-- @param   table       Module instance (self)
-- @param   table       Response object
-- @return  function    Iterator, returning chunk, err, has_esi for each call
--------------------------------------------------------------------------------
function _M.get_reader(self, res)
    local redis = self.redis
    local entity_id = res.entity_id
    local entity_keys = entity_keys(entity_id)
    local num_chunks = redis:llen(entity_keys.body) or 0

    return function()
        local cursor = self._reader_cursor
        self._reader_cursor = cursor + 1

        local has_esi = false

        if cursor < num_chunks then
            local chunk, err = redis:lindex(entity_keys.body, cursor)
            if not chunk then return nil, err, nil end

            local process_esi = self.ctx.esi_process_enabled
            if process_esi then
                has_esi, err = redis:lindex(entity_keys.body_esi, cursor)
                if not has_esi then return nil, err, nil end
            end

            if chunk == ngx_null or (process_esi and has_esi == ngx_null) then
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


--------------------------------------------------------------------------------
-- Returns an iterator which writes chunks to cache as they are read from
-- reader belonging to the repsonse object.
-- If we cross the maxsize boundary, or error for any reason, we just
-- keep yielding chunks to be served, after having removed the cache entry.
--------------------------------------------------------------------------------
-- @param   table       Module instance (self)
-- @param   table       Response object
-- @param   number      time-to-live
-- @param   function    onsuccess callback
-- @param   function    onfailure callback
-- @return  function    Iterator, returning chunk, err, has_esi for each call
--------------------------------------------------------------------------------
function _M.get_writer(self, res, ttl, onsuccess, onfailure)
    assert(type(res) == "table")
    assert(type(ttl) == "number")
    assert(type(onsuccess) == "function")
    assert(type(onfailure) == "function")

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
            local ok, e = redis:exec() -- Commit

            if not ok or ok == ngx_null then
                -- Transaction failed
                ok, e = pcall(onfailure, e)
                if not ok then ngx_log(ngx_ERR, e) end
            else
                -- All good, report success
                ok, e = pcall(onsuccess, size)
                if not ok then ngx_log(ngx_ERR, e) end
            end

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
