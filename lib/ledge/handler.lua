local setmetatable = setmetatable

local util = require("ledge.util")
local fixed_field_metatable = util.mt.fixed_field_metatable

local _M = {
    _VERSION = "1.28.3",
}


local function new(config)
    if not config then return nil, "config table expected" end

    config = setmetatable(config, fixed_field_metatable)
    return setmetatable({ 
        config = config 

    }, {
        __index = _M,
    })
end
_M.new = new


local function run(self)
    return true
end
_M.run = run


return setmetatable(_M, fixed_field_metatable)
