local ledge = require("ledge")
local util = require("ledge.util")

local setmetatable = setmetatable

local ngx_req_get_method = ngx.req.get_method
local ngx_req_http_version = ngx.req.http_version

local ngx_re_find = ngx.re.find

local ngx_flush = ngx.flush

local ngx_log = ngx.log
local ngx_INFO = ngx.INFO

local ngx_var = ngx.var

local tbl_insert = table.insert
local tbl_concat = table.concat

local fixed_field_metatable = util.mt.fixed_field_metatable
local get_fixed_field_metatable_proxy = util.mt.get_fixed_field_metatable_proxy


-- http://www.w3.org/Protocols/rfc2616/rfc2616-sec13.html#sec13.5.1
local HOP_BY_HOP_HEADERS = {
    ["connection"]          = true,
    ["keep-alive"]          = true,
    ["proxy-authenticate"]  = true,
    ["proxy-authorization"] = true,
    ["te"]                  = true,
    ["trailers"]            = true,
    ["transfer-encoding"]   = true,
    ["upgrade"]             = true,
    ["content-length"]      = true,  -- Not strictly hop-by-hop, but we set
                                     -- dynamically downstream.
}


local WARNINGS = {
    ["110"] = "Response is stale",
    ["214"] = "Transformation applied",
    ["112"] = "Disconnected Operation",
}


local _M = {
    _VERSION = "1.28.3",
}


-- Creates a new handler instance.
--
-- Config defaults are provided in the ledge module, and so instances
-- should always be created with ledge.create_handler(), not directly.
--
-- @param   table   The complete config table
-- @return  table   Handler instance, or nil if no config table is provided
local function new(config)
    if not config then return nil, "config table expected" end
    config = setmetatable(config, fixed_field_metatable)

    return setmetatable({
        config = config,
        redis = {},
        storage = {},
    }, get_fixed_field_metatable_proxy(_M))
end
_M.new = new


local function run(self)
    local redis, err = ledge.create_redis_connection()
    if not redis then
        return nil, "could not connect to redis, " .. tostring(err)
    else
        self.redis = redis
    end

    -- Create storage connection
    local config = self.config
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
