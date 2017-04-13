local util = require("ledge.util")

local setmetatable, require =
    setmetatable, require

local ngx_get_phase = ngx.get_phase

local fixed_structure_metatable = util.table.fixed_structure_metatable


local _M = {
    _VERSION = '1.29.3',
}


local params = setmetatable({
    -- Default Redis metadata connection params
    redis_params = setmetatable({
        connect_timeout = 500,      -- (ms)
        read_timeout = 5000,        -- (ms)
        keeapalive_timeout = 60000, -- (ms)
        keepalive_poolsize = 30,
        redis_connector = {
            url = "redis://127.0.0.1:6379/0",
        },
        qless_db = 2,
    }, fixed_structure_metatable),

    -- Default storage driver params
    storage_driver = require("ledge.storage.redis"),
    storage_params = setmetatable({
        connect_timeout = 500,      -- (ms)
        read_timeout = 5000,        -- (ms)
        keeapalive_timeout = 60000, -- (ms)
        keepalive_poolsize = 30,
        redis_connector = {
            url = "redis://127.0.0.1:6379/3",
        },
    }, fixed_structure_metatable),
}, fixed_structure_metatable)


local function set(param, value)
    if ngx_get_phase() ~= "init" then
        error("attempt to set params outside of the 'init' phase", 2)
    else
        params[param] = value
    end
end
_M.set = set


local function get(param)
    return params[param]
end
_M.get = get


local function create_worker(config)
    return { run = function() return nil end }
end
_M.create_worker = create_worker


local function create_handler(config)
    return { run = function() return nil end }
end
_M.create_handler = create_handler


return setmetatable(_M, fixed_structure_metatable)
