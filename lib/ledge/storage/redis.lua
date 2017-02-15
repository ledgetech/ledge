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
    _VERSION = "1.28"
}

local mt = {
    __index = _M,
}


-- Redis key namespace
local KEY_PREFIX = "ledge:entity:"


--- Creates a new (disconnected) storage instance.
-- @param   ledge   Referenence to the ledge module
-- @param   ctx     Request context
-- @return  The module instance
function _M.new(ledge, ctx)
    return setmetatable({
        ledge = ledge,
        ctx = ctx,
        redis = nil,
        reader_cursor = 0,
        -- TODO: max memory from config
--        body_max_memory = 2048, -- (KB) Max size for a cache body before we bail on trying to store.
    }, mt)
end


--- Connects to the Redis storage backend
-- @param   params  Redis connection parameters as per lua-resty-redis-connector
-- @see     https://github.com/pintsized/lua-resty-redis-connector
-- @usage   The params table can also include
function _M.connect(self, params)
    local rc = redis_connector.new()

    -- Set timeout / connection options
    local   connect_timeout, read_timeout, connection_options =
            params.connect_timeout, params.read_timeout, params.connection_options

    if connect_timeout then rc:set_connect_timeout(connect_timeout) end
    if read_timeout then rc:set_read_timeout(read_timeout) end
    if connection_options then rc:set_connection_options(connection_options) end

    -- Connect
    local redis, err = rc:connect(params)
    if not redis then
        return nil, err
    else
        self.redis = redis
        return true, nil
    end
end


-- Return the Redis keys for the entity; entity_id
local function entity_keys(entity_id)
    if entity_id then
        return {
            body        = KEY_PREFIX .. entity_id .. ":body", -- list
            body_esi    = KEY_PREFIX .. entity_id .. ":body_esi", -- list
            size        = KEY_PREFIX .. entity_id .. ":size", -- string
            has_esi     = KEY_PREFIX .. entity_id .. ":has_esi", -- string
        }
    end
end


-- Returns a boolean indicating if the entity exists, or nil, err
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


function _M.size(self, entity_id)
    return self.redis:get(entity_keys(entity_id).size)
end


function _M.has_esi(self, entity_id)
    local res, err = self.redis:get(entity_keys(entity_id).has_esi)
    if res and res ~= ngx_null then
        return res
    end
end


--- Returns an iterator for reading the body chunks.
-- @param   entity_id   The entity ID
-- @return  chunk       The chunk data, or nil indicating error or end of stream
-- @return  err         Error message
-- @return  has_esi     Boolean to indicate presence of ESI instructions
function _M.get_reader(self, entity_id)
    local redis = self.redis
    local entity_keys = entity_keys(entity_id)
    local num_chunks = redis:llen(entity_keys.body) or 0

    return function()
        local cursor = self.reader_cursor
        self.reader_cursor = cursor + 1

        local has_esi = false

        if cursor < num_chunks then
            local chunk, err = redis:lindex(entity_keys.body, cursor)
            if not chunk then return nil, err, nil end

            -- Only bother with the body_esi list if we know there are some chunks marked as true
            -- The body server is responsible for deciding whether to actually call process_esi() or not.
            local process_esi = self.ctx.esi_process_enabled
            if process_esi then
                has_esi, err = redis:lindex(entity_keys.body_esi, cursor)
                if not has_esi then return nil, err, nil end
            end

            if chunk == ngx_null or (process_esi and has_esi == ngx_null) then
                ngx_log(ngx_WARN, "entity removed during read, ", entity_keys.main)
                -- Jump out using the state machine
                -- TODO: Is this necessary? Do we need to know why we're finished other than to log
                -- it. Surely we just "exit" normally? Would be nice if drivers didn't need to program
                -- the state machine
                return self.ledge:e "entity_removed_during_read"
            end

            return chunk, nil, has_esi == "true"
        end
    end
end


-- Returns a wrapped coroutine for writing chunks to cache, where reader is a
-- coroutine to be resumed which reads from the upstream socket.
-- If we cross the body_max_memory boundary, we just keep yielding chunks to be served,
-- after having removed the cache entry.
function _M.get_writer(self, entity_id, reader, ttl)
    local redis = self.redis
    local max_memory = (self.body_max_memory or 0) * 1024
    local transaction_aborted = false
    local esi_detected = false
    local esi_parser = nil

    -- new
    local entity_keys = entity_keys(entity_id)
    redis:multi()

    local size = 0
    return function(buffer_size)
        repeat
            local chunk, err, has_esi = reader(buffer_size)
            if chunk then
                if not transaction_aborted then
                    size = size + #chunk

                    -- If we cannot store any more, delete everything.
                    if size > max_memory then
                        local res, err = redis:discard()
                        if err then
                            ngx_log(ngx_ERR, err)
                        end
                        transaction_aborted = true

                        local ok, err = self:delete()
                        if err then
                            ngx_log(ngx_ERR, "error deleting body: ", err)
                        else
                            ngx_log(ngx_NOTICE, "body could not be stored as it is larger than ",
                                                max_memory, " bytes")
                        end
                    else
                        local ok, err = redis:rpush(entity_keys.body, chunk)
                        if not ok then
                            transaction_aborted = true
                            ngx_log(ngx_ERR, "error writing cache chunk: ", err)
                        end
                        local ok, err = redis:rpush(entity_keys.body_esi, tostring(has_esi))
                        if not ok then
                            transaction_aborted = true
                            ngx_log(ngx_ERR, "error writing chunk esi flag: ", err)
                        end

                        if not esi_detected and has_esi then
                            ngx.log(ngx.DEBUG, "setting parser")
                            esi_parser = self.ledge:ctx().esi_parser
                            if not esi_parser or not esi_parser.token then
                                ngx_log(ngx_ERR, "ESI detected but no parser identified")
                            else
                                esi_detected = true
                            end
                        end
                    end
                end

                -- Return the chunk
                return chunk, nil, has_esi

            elseif size == 0 then
                local ok, err = redis:rpush(entity_keys.body, "")
                if not ok then
                    transaction_aborted = true
                    ngx_log(ngx_ERR, "error writing blank cache chunk: ", err)
                end
                local ok, err = redis:rpush(entity_keys.body_esi, tostring(has_esi))
                if not ok then
                    transaction_aborted = true
                    ngx_log(ngx_ERR, "error writing chunk esi flag: ", err)
                end
            end
        until not chunk

        if not transaction_aborted then
            -- Set size
            redis:set(entity_keys.size, size)
            if esi_parser then
                redis:set(entity_keys.has_esi, esi_parser.token)
            end

            -- Set expiries
            redis:expire(entity_keys.body, ttl)
            redis:expire(entity_keys.body_esi, ttl)
            redis:expire(entity_keys.size, ttl)
            redis:expire(entity_keys.has_esi, esi_detected)

            local res, err = redis:exec()
            if err then
                ngx_log(ngx_ERR, "error executing cache transaction: ",  err)
            end

            --return res, err --entity_id --, size, esi_detected, (esi_parser.token or nil)
        else
            -- If the transaction was aborted make sure we discard
            -- May have been discarded cleanly due to memory so ignore errors
            redis:discard()

            -- Returning nil should abort the outer (metadata) transaction too
            -- TODO: Previous behavior was to delete cache item if transaction aborted due
            -- to memory size, but simply fail for any other reason.
            --return nil, "body writer transaction aborted"
        end
    end
end


function _M.delete(self, entity_id)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        local keys = {}
        for k, v in pairs(key_chain) do
            tbl_insert(keys, v)
        end
        return self.redis:del(unpack(keys))
    end
end


function _M.expire(self, entity_id, ttl)
    local key_chain = entity_keys(entity_id)
    if key_chain then
        for _,key in pairs(key_chain) do
            self.redis:expire(key, ttl)
        end
    end
end


-- Deferred deletion, allowing existing reads to complete.
function _M.collect(self, entity_id)
    ngx.log(ngx.DEBUG, "will collect: ", entity_id)
    local ledge = self.ledge

    local size, err = self:size(entity_id)
    if not size or size == ngx_null then
        ngx_log(ngx_ERR, err)
        size = 0
    end

    local delay = ledge:gc_wait(size)
    ledge:put_background_job("ledge", "ledge.jobs.collect_entity", {
        entity_id = entity_id,
    }, {
        delay = size,
        tags = { "collect_entity" },
        priority = 10,
    })
end


return _M
