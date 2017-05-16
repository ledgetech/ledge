local events = require("ledge.state_machine.events")
local states = require("ledge.state_machine.states")
local actions = require("ledge.state_machine.actions")

local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR


local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _DEBUG = false

local _M = {
    _VERSION = "1.28.3",
    set_debug = function(debug) _DEBUG = debug end,
}


local function new(handler)
    return setmetatable({
        handler = handler,
        state_history = {},
        event_history = {},
        current_state = "",
    }, get_fixed_field_metatable_proxy(_M))
end
_M.new = new


-- Transition to a new state.
local function t(self, state)
    -- Check for any transition pre-tasks
    local pre_t = events.pre_transitions[state]

    if pre_t then
        for _,action in ipairs(pre_t) do
            if _DEBUG then ngx_log(ngx_DEBUG, "#a: ", action) end
            local ok, err = pcall(actions[action], self.handler)
            if not ok then
                ngx_log(ngx_ERR, "failed to call action: ", tostring(err))
            end
        end
    end

    if _DEBUG then ngx_log(ngx_DEBUG, "#t: ", state) end

    self.state_history[state] = true
    self.current_state = state
    return states[state](self, self.handler)
end
_M.t = t


return _M
