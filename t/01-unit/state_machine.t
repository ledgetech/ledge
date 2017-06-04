use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        assert(require("ledge.state_machine"),
            "state machine module should include without error")

        assert(require("ledge.state_machine.events"),
            "events module should include without error")

        assert(require("ledge.state_machine.pre_transitions"),
            "pre_transitions module should include without error")

        assert(require("ledge.state_machine.states"),
            "events module should include without error")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 2: Prove station machine compiles
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local events = require("ledge.state_machine.events")
        local pre_transitions = require("ledge.state_machine.pre_transitions")
        local states = require("ledge.state_machine.states")
        local actions = require("ledge.state_machine.actions")

        for ev,t in pairs(events) do
            for _,trans in ipairs(t) do
                -- Check states
                for _,kw in ipairs { "when", "after", "begin" } do
                    if trans[kw] then
                        if "function" ~= type(states[trans[kw]]) then
                            ngx.say("State '", trans[kw], "' requested during ",
                                ev, " is not defined")
                        end
                    end
                end

                -- Check "in_case" previous event
                if trans["in_case"] then
                    if not events[trans["in_case"]] then
                        ngx.say("Event '", trans["in_case"],
                            "' filtered for but not in transition table")
                    end
                end

                -- Check actions
                if trans["but_first"] then
                    local action = trans["but_first"]
                    if type(action) == "table" then
                        for _,ac in ipairs(action) do
                            if "function" ~= type(actions[ac]) then
                                ngx.say("Action '", ac, "' called during ", ev,
                                    " is not defined")
                            end
                        end
                    else
                        if "function" ~= type(actions[action]) then
                            ngx.say("Action '", action, "' called during ", ev,
                                " is not defined")
                        end
                    end
                end
            end
        end

        for t,v in pairs(pre_transitions) do
            if "function" ~= type(states[t]) then
                ngx.say("Pre-transitions defined for missing state '", t, "'")
            end
            if type(v) ~= "table" or #v == 0 then
                ngx.say("No pre-transition actions defined for '", t, "'")
            else
                for _,action in ipairs(v) do
                    if "function" ~= type(actions[action]) then
                        ngx.say("Pre-transition action '", action,
                            "' is not defined")
                    end
                end
            end
        end

        for state, v in pairs(states) do
            local found = false
            for ev, t in pairs(events) do
                for _, trans in ipairs(t) do
                    if trans["begin"] == state then
                        found = true
                    end
                end
            end

            if found == false then
                ngx.say("State '", state, "' is never transitioned to")
            end
        end


        local states_file = "lib/ledge/state_machine/states.lua"
        local handler_file = "lib/ledge/handler.lua"

        -- event in a table
        local events_called = {}
        for _, file in ipairs({ states_file, handler_file }) do
            assert(io.open(file, "r"),
                "Could not find states.lua (are you running from the root dir?")

            -- Run luac to extract self:e(event) calls by event name
            local cmd = "luac -p -l " .. file
            cmd = cmd .. [[ | grep -A2 'SELF .* "e"' | awk '{print $7}']]
            cmd = cmd .. [[ | grep "\".*\""]]
            local f, err = io.popen(cmd, "r")

            -- For each call, check the event being triggered exists, and place the
            repeat
                local event = f:read('*l')
                if event then
                    event = ngx.re.gsub(event, "\"", "") -- remove quotes
                    events_called[event] = true
                    if not events[event] then
                        ngx.say("Event '", event, "' is called but does not exist")
                    end
                end
            until not event

            f:close()
        end

        for event, t_table in pairs(events) do
            if not events_called[event] then
                ngx.say("Event '", event, "' exits but is never called")
            end
        end

        ngx.say("OK")
    }
}
--- request
GET /t
--- response_body
OK
--- no_error_log
[error]
