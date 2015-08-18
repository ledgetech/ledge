use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        local ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
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
        content_by_lua '
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

            ngx.say("OK")
        ';
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
