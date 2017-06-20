local setmetatable, require, error =
    setmetatable, require, error


local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_get_phase = ngx.get_phase
local ngx_null = ngx.null

local tbl_insert = table.insert

local util = require("ledge.util")
local tbl_copy = util.table.copy
local tbl_copy_merge_defaults = util.table.copy_merge_defaults
local fixed_field_metatable = util.mt.fixed_field_metatable
local get_fixed_field_metatable_proxy = util.mt.get_fixed_field_metatable_proxy

local redis_connector = require("resty.redis.connector")


local _M = {
    _VERSION = "1.28.3",

    ORIGIN_MODE_BYPASS = 1, -- Never go to the origin, serve from cache or 503
    ORIGIN_MODE_AVOID  = 2, -- Avoid the origin, serve from cache where possible
    ORIGIN_MODE_NORMAL = 4, -- Assume the origin is happy, use at will
}


local config = setmetatable({
    redis_connector_params = {
        connect_timeout = 500,      -- (ms)
        read_timeout = 5000,        -- (ms)
        keepalive_timeout = 60000,  -- (ms)
        keepalive_poolsize = 30,
    },

    qless_db = 1,
}, fixed_field_metatable)


local function configure(user_config)
    assert(ngx_get_phase() == "init",
        "attempt to call configure outside the 'init' phase")

    config = setmetatable(
        tbl_copy_merge_defaults(user_config, config),
        fixed_field_metatable
    )
end
_M.configure = configure


local handler_defaults = setmetatable({
    storage_driver = "ledge.storage.redis",
    storage_driver_config = {},

    origin_mode = _M.ORIGIN_MODE_NORMAL,  -- TODO rename upstream mode?
    upstream_connect_timeout = 500,  -- (ms)
    upstream_read_timeout = 5000,    -- (ms)
    upstream_host = "127.0.0.1",
    upstream_port = 80,
    upstream_use_ssl = false,
    upstream_ssl_server_name = "",
    upstream_ssl_verify = true,

    use_resty_upstream = false,
    resty_upstream = nil,

    buffer_size = 2^16,
    advertise_ledge = true,
    keep_cache_for  = 86400 * 30,  -- (sec)
    minimum_old_entity_download_rate = 56,

    esi_enabled = false,
    esi_content_types = { "text/html" },
    esi_allow_surrogate_delegation = false,
    esi_recursion_limit = 10,
    esi_pre_include_callback = nil,
    esi_args_prefix = "esi_",

    enable_collapsed_forwarding = false,
    collapsed_forwarding_window = 60 * 1000,

    gunzip_enabled = true,
    keyspace_scan_count = 10,

    cache_key_spec = {},  -- No default as we don't ever wish to merge it

}, fixed_field_metatable)


-- events are not fixed field to avoid runtime fatal errors from bad config
-- ledge.bind() and handler:bind() both check validity of event names however.
local event_defaults = {
    after_cache_read = {},
    before_upstream_request = {},
    after_upstream_request = {},
    before_save = {},
    before_save_revalidation_data = {},
    before_serve = {},
    before_esi_include_request = {},
}


local function set_handler_defaults(user_config)
    assert(ngx_get_phase() == "init",
        "attempt to call set_handler_defaults outside the 'init' phase")

    handler_defaults = setmetatable(
        tbl_copy_merge_defaults(user_config, handler_defaults),
        fixed_field_metatable
    )
end
_M.set_handler_defaults = set_handler_defaults


local function bind(event, callback)
    local ev = event_defaults[event]
    assert(ev, "no such event: " .. tostring(event))

    tbl_insert(ev, callback)
    return true
end
_M.bind = bind


local function create_worker(config)
    return require("ledge.worker").new(config)
end
_M.create_worker = create_worker


local function create_handler(config)
    local config = tbl_copy_merge_defaults(config, handler_defaults)
    return require("ledge.handler").new(config, tbl_copy(event_defaults))
end
_M.create_handler = create_handler


local function create_redis_connection()
    return redis_connector.new(
        config.redis_connector_params
    ):connect()
end
_M.create_redis_connection = create_redis_connection


local function close_redis_connection(redis)
    return redis_connector.new(
        config.redis_connector_params
    ):set_keepalive(redis)
end
_M.close_redis_connection = close_redis_connection


local function create_qless_connection()
    local redis, err = create_redis_connection()
    if not redis then return nil, err end

    local ok, err = redis:select(config.qless_db)
    if not ok or ok == ngx_null then return nil, err end

    return redis
end
_M.create_qless_connection = create_qless_connection


local function create_storage_connection(driver_module, storage_driver_config)
    -- Take config by value, and merge with defaults
    storage_driver_config = tbl_copy_merge_defaults(
        storage_driver_config or {},
        handler_defaults.storage_driver_config
    )

    if not driver_module then
        driver_module = handler_defaults.storage_driver
    end

    local ok, module = pcall(require, driver_module)
    if not ok then return nil, module end

    local ok, driver = pcall(module.new)
    if not ok then return nil, driver end

    local ok, conn = pcall(driver.connect, driver, storage_driver_config)
    if not ok then return nil, conn end

    return conn, nil
end
_M.create_storage_connection = create_storage_connection


local function close_storage_connection(storage)
    return storage:close()
end
_M.close_storage_connection = close_storage_connection


return setmetatable(_M, fixed_field_metatable)
