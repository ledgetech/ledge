local redis = require "resty.redis"
local redis_connector = require "resty.redis.connector"


local   tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable =
        tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable

local ngx_null = ngx.null
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_NOTICE = ngx.NOTICE
local ngx_WARN = ngx.WARN

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


local KEY_PREFIX = "ledge:entity:"


function _M.new()
    return setmetatable({
        redis = nil,
        connect_timeout = 100,
        read_timeout = 1000,
        connection_options = nil, -- pool, etc
        body_max_memory = 2048, -- (KB) Max size for a cache body before we bail on trying to store.
    }, mt)
end


function _M.set_connect_timeout(self, timeout)
    self.connect_timeout = timeout
end


function _M.set_read_timeout(self, timeout)
    self.read_timeout = timeout
end


function _M.set_connection_options(self, options)
    self.connection_options = options
end


function _M.connect(self, params)
    local rc = redis_connector.new()
    rc:set_connect_timeout(self.connect_timeout)
    rc:set_read_timeout(self.read_timeout)

    local redis, err = rc:connect(params)
    if not redis then
        ngx_log(ngx_ERR, err)
    else
        self.redis = redis
    end
end


local function entity_keys(entity_id)
    return setmetatable({
        body = KEY_PREFIX .. entity_id .. ":body", -- list
        body_esi = KEY_PREFIX .. entity_id .. ":body_esi", -- list
    }, { __index = {
        -- Hide the id from iterators
        entity_id = entity_id,
    }})
end


function _M.exists(self, entity_id)
    local keys = entity_keys(entity_id)
    local redis = self.redis

    local res, err = redis:exists(keys.body, keys.body_esi)
    if not res and err then
        return nil, err
    elseif res == ngx_null or res == 0 then
        return nil, "entity is missing"
    else
        return true, nil
    end
end


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
                -- TODO: how to bail out?
                --return self:e "entity_removed_during_read"
            end

            co_yield(chunk, nil, has_esi == "true")
        end
    end)
end


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

                        local ok, err = self:delete_from_cache()
                        if err then
                            ngx_log(ngx_ERR, "error deleting from cache: ", err)
                        else
                            ngx_log(ngx_NOTICE, "cache item deleted as it is larger than ",
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

            return nil, "body writer transaction aborted"
        end
    end)
end


function _M.delete(self, entity_id)
    return self.redis:del(unpack(entity_keys(entity_id)))
end


return _M
