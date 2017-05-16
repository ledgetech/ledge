local ledge = require("ledge")
local util = require("ledge.util")

local setmetatable = setmetatable

local ngx_req_get_method = ngx.req.get_method

local ngx_re_find = ngx.re.find

local ngx_var = ngx.var

local tbl_insert = table.insert
local tbl_concat = table.concat

local fixed_field_metatable = util.mt.fixed_field_metatable
local get_fixed_field_metatable_proxy = util.mt.get_fixed_field_metatable_proxy

local _M = {
    _VERSION = "1.28.3",
}


-- Creates a new handler instance.
--
-- Config defaults are provided in the ledge module, and so instances
-- should always be created with ledge.create_handler(), not directly.
--
-- @param   table   The complete config table
-- @return  table   Handler instance or nil, err if not Redis is available
local function new(config)
    if not config then return nil, "config table expected" end

    config = setmetatable(config, fixed_field_metatable)

    local redis, err = ledge.create_redis_connection()
    if not redis then
        return nil, "could not connect to redis, " .. tostring(err)
    end

    return setmetatable({
        config = config,
        redis = redis,
        storage = {},
    }, get_fixed_field_metatable_proxy(_M))
end
_M.new = new


local function run(self)
    local config = self.config

    -- Create storage connection
    local storage, err = ledge.create_storage_connection(
        config.storage_driver,
        config.storage_driver_config
    )
    if not storage then
        return nil, "could not connect to storage, " .. tostring(err)
    else
        self.storage = storage
    end

    return true
end
_M.run = run


return setmetatable(_M, fixed_field_metatable)
