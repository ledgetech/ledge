use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require "resty.core"
        end
        ledge_mod = require "ledge.ledge"
        ledge = ledge_mod:new()
        ledge:config_set("redis_database", $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set("redis_qless_database", $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set("upstream_host", "127.0.0.1")
        ledge:config_set("upstream_port", 1984)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
        pwd = '$pwd'
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Load module without errors.
--- http_config eval: $::HttpConfig
--- config
    location /sanity_1 {
        echo "OK";
    }
--- request
GET /sanity_1
--- no_error_log
[error]


=== TEST 2: Check state machine "compiles".
--- http_config eval: $::HttpConfig
--- config
    location /sanity_2 {
        content_by_lua_block {
            for ev,t in pairs(ledge.events) do
                for _,trans in ipairs(t) do
                    -- Check states
                    for _,kw in ipairs { "when", "after", "begin" } do
                        if trans[kw] then
                            if "function" ~= type(ledge.states[trans[kw]]) then
                                ngx.say("State ", trans[kw], " requested during ", ev, " is not defined")
                            end
                        end
                    end

                    -- Check "in_case" previous event
                    if trans["in_case"] then
                        if not ledge.events[trans["in_case"]] then
                            ngx.say("Event ", trans["in_case"], " filtered for but is not in transition table")
                        end
                    end

                    -- Check actions
                    if trans["but_first"] then
                        local action = trans["but_first"]
                        if type(action) == "table" then
                            for _,ac in ipairs(action) do
                                if "function" ~= type(ledge.actions[ac]) then
                                    ngx.say("Action ", ac, " called during ", ev, " is not defined")
                                end
                            end
                        else
                            if "function" ~= type(ledge.actions[action]) then
                                ngx.say("Action ", action, " called during ", ev, " is not defined")
                            end
                        end
                    end
                end
            end

            for t,v in pairs(ledge.pre_transitions) do
                if "function" ~= type(ledge.states[t]) then
                    ngx.say("Pre-transitions defined for missing state ", t)
                end
                if type(v) ~= "table" or #v == 0 then
                    ngx.say("No pre-transition actions defined for "..t)
                else
                    for _,action in ipairs(v) do
                        if "function" ~= type(ledge.actions[action]) then
                            ngx.say("Pre-transition action ", action, " is not defined")
                        end
                    end
                end
            end

            for state, v in pairs(ledge.states) do
                local found = false
                for ev, t in pairs(ledge.events) do
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


            -- Run luac to extract self:e(event) calls by event name
            local cmd = "luac -p -l " .. pwd .. "/lib/ledge/ledge.lua"
            cmd = cmd .. [[ | grep -A2 'SELF .* "e"' | awk '{print $7}' | grep "\".*\""]]
            local f = io.popen(cmd, 'r')

            -- For each call, check the event being triggered exists, and place the event in a table
            local events_called = {}
            repeat
                local event = f:read('*l')
                if event then
                    event = ngx.re.gsub(event, "\"", "") -- remove surrounding quotes
                    events_called[event] = true
                    if not ledge.events[event] then
                        ngx.say("Event '", event, "' is called but does not exist")
                    end
                end
            until not event

            for event, t_table in pairs(ledge.events) do
                if not events_called[event] then
                    ngx.say("Event '", event, "' exits but is never called")
                end
            end

            f:close()

            ngx.say("OK")
        }
    }
--- request
GET /sanity_2
--- no_error_log
[error]
--- response_body
OK


=== TEST 3: Run module without errors, returning origin content.
--- http_config eval: $::HttpConfig
--- config
    location /sanity_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /sanity_2 {
        echo "OK";
    }
--- request
GET /sanity_2_prx
--- no_error_log
[error]
--- response_body
OK


=== TEST 4: Run module against Redis on a Unix socket without errors.
--- http_config eval: $::HttpConfig
--- config
    location /sanity_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("redis_hosts", {
                { socket = redis_socket },
            })
            ledge:run()
        ';
    }
    location /sanity_4 {
        echo "OK";
    }
--- request
GET /sanity_4_prx
--- no_error_log
[error]
--- response_body
OK


=== TEST 4: Request with encoded spaces, without errors.
--- http_config eval: $::HttpConfig
--- config
    location "/sanity _4_prx" {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location "/sanity _4" {
        echo "OK";
    }
--- request
GET /sanity%20_4_prx
--- no_error_log
[error]
--- response_body
OK
