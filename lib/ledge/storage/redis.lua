local redis = require "resty.redis"
local redis_connector = require "resty.redis.connector"

local   tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable =
        tostring, ipairs, pairs, type, tonumber, next, unpack, setmetatable

local ngx_log = ngx.log


local _M = {
    _VERSION = "1.28"
}

local mt = {
    __index = _M,
}


function _M.new()
    return setmetatable({
        redis = nil,
        connect_timeout = 100,
        read_timeout = 1000,
        connection_options = nil, -- pool, etc
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


function _M.connect(params)
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


local function entity_keys(entity)
    local prefix = "ledge:entity:"
    return setmetatable({
        body = prefix .. entity_id .. ":body", -- list
        body_esi = prefix .. entity_id .. ":body_esi", -- list
    }, { __index = {
        -- Hide the id from iterators
        entity_id = entity_id,
    }})
end


function _M.exists(entity)
    local keys = entity_keys(entity)
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


function _M.get_reader(entity)

end


function _M.get_writer(entity, reader, ttl)

end


function _M.delete(entity)
    return self.redis:del(unpack(entity_keys(entity)))
end


return _M
