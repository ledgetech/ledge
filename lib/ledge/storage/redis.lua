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
    _VERSION = "1.28"
}

local mt = {
    __index = _M,
}


-- Redis key namespace
local KEY_PREFIX = "ledge:entity:"


function _M.new()
    return setmetatable({
        redis = nil,
        body_max_memory = 2048, -- (KB) Max size for a cache body before we bail on trying to store.
    }, mt)
end


function _M.connect(self, params)
    local rc = redis_connector.new()

    if params.connect_timeout then
        rc:set_connect_timeout(self.connect_timeout)
    end

    if params.read_timeout then
        rc:set_read_timeout(self.read_timeout)
    end

    if params.connection_options then
        rc:set_connection_options()
    end

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
            body = KEY_PREFIX .. entity_id .. ":body", -- list
            body_esi = KEY_PREFIX .. entity_id .. ":body_esi", -- list
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


-- Returns a reader function, yielding chunk, err, has_esi
function _M.get_reader(self, entity_id)
    local redis = self.redis
    local entity_keys = entity_keys(entity_id)

    local num_chunks = redis:llen(entity_keys.body) - 1
    if num_chunks < 0 then return nil end

    return co_wrap(function()
        for i = 0, num_chunks do
            local chunk, err = redis:lindex(entity_keys.body, i)
            local has_esi, err = redis:lindex(entity_keys.body_esi, i)

            if chunk == ngx_null then
                ngx_log(ngx_WARN, "entity removed during read, ", entity_keys.main)
                --return self:e "entity_removed_during_read"
                -- TODO: how to bail out? For now, we return an error
                return nil, "entity removed during read"
            end

            co_yield(chunk, nil, has_esi == "true")
        end
    end)
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

    return co_wrap(function(buffer_size)
        local size = 0
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
                            esi_parser = self:ctx().esi_parser
                            if not esi_parser or not esi_parser.token then
                                ngx_log(ngx_ERR, "ESI detected but no parser identified")
                            else
                                esi_detected = true
                            end
                        end
                    end
                end
                co_yield(chunk, nil, has_esi)
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
            -- Set expiries
            redis:expire(entity_keys.body, ttl)
            redis:expire(entity_keys.body_esi, ttl)

            local res, err = redis:exec()
            if err then
                ngx_log(ngx_ERR, "error executing cache transaction: ",  err)
            end

            return entity_id, size, esi_detected, (esi_parser.token or nil)
        else
            -- If the transaction was aborted make sure we discard
            -- May have been discarded cleanly due to memory so ignore errors
            redis:discard()

            -- Returning nil should abort the outer (metadata) transaction too
            -- TODO: Previous behavior was to delete cache item if transaction aborted due
            -- to memory size, but simply fail for any other reason.
            return nil, "body writer transaction aborted"
        end
    end)
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


return _M
