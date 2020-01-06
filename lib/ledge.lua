local setmetatable, require =
    setmetatable, require

local ngx_get_phase = ngx.get_phase
local ngx_null = ngx.null

local tbl_insert = table.insert

local util = require("ledge.util")
local tbl_copy = util.table.copy
local tbl_copy_merge_defaults = util.table.copy_merge_defaults
local fixed_field_metatable = util.mt.fixed_field_metatable

local redis_connector = require("resty.redis.connector")


local _M = {
    _VERSION = "2.3.0",

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

    origin_mode = _M.ORIGIN_MODE_NORMAL,

    -- Note that upstream timeout and keepalive config is shared with outbound
    -- ESI request, which are not necessarily configured to use this "upstream"
    upstream_connect_timeout = 1000,  -- (ms)
    upstream_send_timeout = 2000,  -- (ms)
    upstream_read_timeout = 10000,  -- (ms)
    upstream_keepalive_timeout = 75000,  -- (ms)
    upstream_keepalive_poolsize = 64,

    upstream_host = "",
    upstream_port = 80,
    upstream_use_ssl = false,
    upstream_ssl_server_name = "",
    upstream_ssl_verify = true,

    advertise_ledge = true,
    visible_hostname = util.get_hostname(),

    buffer_size = 2^16,
    keep_cache_for  = 86400 * 30,  -- (sec)
    minimum_old_entity_download_rate = 56,

    esi_enabled = false,
    esi_content_types = { "text/html" },
    esi_allow_surrogate_delegation = false,
    esi_recursion_limit = 10,
    esi_args_prefix = "esi_",
    esi_max_size = 1024 * 1024,  -- (bytes)
    esi_custom_variables = {},
    esi_attempt_loopback = true,
    esi_vars_cookie_blacklist = {},

    esi_disable_third_party_includes = false,
    esi_third_party_includes_domain_whitelist = {},

    enable_collapsed_forwarding = false,
    collapsed_forwarding_window = 60 * 1000,

    gunzip_enabled = true,
    keyspace_scan_count = 10,

    cache_key_spec = {},  -- No default as we don't ever wish to merge it
    max_uri_args = 100,

}, fixed_field_metatable)


-- events are not fixed field to avoid runtime fatal errors from bad config
-- ledge.bind() and handler:bind() both check validity of event names however.
local event_defaults = {
    after_cache_read = {},
    before_upstream_connect = {},
    before_upstream_request = {},
    after_upstream_request = {},
    before_vary_selection = {},
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
    assert(ngx_get_phase() == "init",
        "attempt to call bind outside the 'init' phase")

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
    local rc, err = redis_connector.new(config.redis_connector_params)
    if not rc then
        return nil, err
    end

    return rc:connect()
end
_M.create_redis_connection = create_redis_connection


local function create_redis_slave_connection()
    local params = tbl_copy_merge_defaults(
        { role = "slave" },
        config.redis_connector_params
    )

    local rc, err = redis_connector.new(params)
    if not rc then
        return nil, err
    end

    return rc:connect()
end
_M.create_redis_slave_connection = create_redis_slave_connection


local function close_redis_connection(redis)
    if not next(redis) then
        -- Possible for this to be called before we've created a redis conn
        -- Ensure we actually have a resty-redis instance to close
        return nil, "No redis connection to close"
    end

    local rc, err = redis_connector.new(config.redis_connector_params)
    if not rc then
        return nil, err
    end

    return rc:set_keepalive(redis)
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

    local ok, driver, err = pcall(module.new)
    if not ok then return nil, driver end
    if not driver then return nil, err end

    local ok, conn, err = pcall(driver.connect, driver, storage_driver_config)
    if not ok then return nil, conn end
    if not conn then return nil, err end

    return conn, nil
end
_M.create_storage_connection = create_storage_connection


local function close_storage_connection(storage)
    return storage:close()
end
_M.close_storage_connection = close_storage_connection


return setmetatable(_M, fixed_field_metatable)
