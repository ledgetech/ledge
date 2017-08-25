local events = require("ledge.state_machine.events")
local pre_transitions = require("ledge.state_machine.pre_transitions")
local states = require("ledge.state_machine.states")
local actions = require("ledge.state_machine.actions")

local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR


local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _DEBUG = false

local _M = {
    _VERSION = "2.0.0",
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
    local pre_t = pre_transitions[state]

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


-- Process state transitions and actions based on the event fired.
local function e(self, event)
    if _DEBUG then ngx_log(ngx_DEBUG, "#e: ", event) end

    self.event_history[event] = true

    -- It's possible for states to call undefined events at run time.
    if not events[event] then
        ngx_log(ngx.CRIT, event, " is not defined.")
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        self:t("exiting")
    end

    for _, trans in ipairs(events[event]) do
        local t_when = trans["when"]
        if t_when == nil or t_when == self.current_state then
            local t_after = trans["after"]
            if not t_after or self.state_history[t_after] then
                local t_in_case = trans["in_case"]
                if not t_in_case or self.event_history[t_in_case] then
                    local t_but_first = trans["but_first"]
                    if t_but_first then
                        if type(t_but_first) == "table" then
                            for _,action in ipairs(t_but_first) do
                                if _DEBUG then
                                    ngx_log(ngx_DEBUG, "#a: ", action)
                                end
                                actions[action](self.handler)
                            end
                        else
                            if _DEBUG then
                                ngx_log(ngx_DEBUG, "#a: ", t_but_first)
                            end
                            actions[t_but_first](self.handler)
                        end
                    end

                    return self:t(trans["begin"])
                end
            end
        end
    end
end
_M.e = e


return _M
