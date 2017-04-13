local util = require("ledge.util")

local setmetatable, pairs, type, tostring, error =
    setmetatable, pairs, type, tostring, error

local get_fixed_field_metatable_proxy =
    util.table.get_fixed_field_metatable_proxy

local _M = {
    _VERSION = "1.28.3",
}


local function new(config)
    local defaults = {
        interval = 1,
        concurrency = 10,
    }

    if config then
        -- Validate config has matching defaults
        for k, v in pairs(config) do
            default_v = defaults[k]
            if not defaults_v or type(defaults_v) ~= type(v) then
                error("invalid config item: " .. tostring(k), 3)
            end
        end
    end

    -- Apply defaults to config
    config = setmetatable(
        config or {},
        get_fixed_field_metatable_proxy(defaults)
    )

    return setmetatable({ config = config }, {
        __index = _M,
    })
end
_M.new = new


local function set(self, param, value)
    self.config[param] = value
end
_M.set = set


local function get(self, param)
    return self.config[param]
end
_M.get = get


local function run(self)
    return true
end
_M.run = run


return _M
