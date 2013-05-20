use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1; 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
	";
};

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
                                ngx.say("State "..trans[kw].." requested during "..ev.." is not defined")
                            end
                        end
                    end

                    -- Check "in_case" previous event
                    if trans["in_case"] then
                        if not ledge.events[trans["in_case"]] then
                            ngx.say("Event "..trans["in_case"].." filtered for but is not in transition table")
                        end
                    end


                    -- Check actions
                    if trans["but_first"] then
                        if "function" ~= type(ledge.actions[trans["but_first"]]) then
                            ngx.say("Action "..trans["but_first"].." called during "..ev.." is not defined")
                        end
                    end
                end
            end

            for t,v in pairs(ledge.pre_transitions) do
                if "function" ~= type(ledge.states[t]) then
                    ngx.say("Pre-transitions defined for missing state "..t)
                end
                if type(v) ~= "table" or #v == 0 then
                    ngx.say("No pre-transition actions defined for "..t)
                else
                    for _,action in ipairs(v) do
                        if "function" ~= type(ledge.actions[action]) then
                            ngx.say("Pre-transition action "..action.." is not defined")
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
	location /sanity_2 {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        echo "OK";
    }
--- request
GET /sanity_2
--- no_error_log
[error]
--- response_body
OK


=== TEST 4: Run module against Redis on a Unix socket without errors.
--- http_config eval: $::HttpConfig
--- config
	location /sanity_4 {
        content_by_lua '
            ledge:config_set("redis_hosts", { 
                { socket = redis_socket },
            })
            ledge:run()
        ';
    }
    location /__ledge_origin {
        echo "OK";
    }
--- request
GET /sanity_4
--- no_error_log
[error]
--- response_body
OK

