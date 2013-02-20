use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test 1m;
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('enable_collapsed_forwarding', true)
    ";
};

run_tests();

__DATA__
=== TEST 1a: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    ';
}
--- request
GET /collapsed
--- repsonse_body
OK
--- no_error_log
[error]


=== TEST 1b: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 2: Concurrent COLD requests accepting cache
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_2", 0)
    ';

    echo_location_async '/collapsed';
    echo_sleep 0.05;
    echo_location_async '/collapsed';
}
location /collapsed {
    content_by_lua 'ledge:run()';
}
location /__ledge_origin { 
    content_by_lua '
        ngx.sleep(0.1)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_2", 1))
    ';
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 1


=== TEST 3a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 3b: Concurrent COLD requests with collapsing turned off
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_3", 0)
    ';

    echo_location_async '/collapsed';
    echo_sleep 0.05;
    echo_location_async '/collapsed';
}
location /collapsed {
    content_by_lua '
        ledge:config_set("enable_collapsed_forwarding", false)
        ledge:run()'
    ;
}
location /__ledge_origin { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_3", 1))
        ngx.sleep(0.1)
    ';
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 4a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Concurrent COLD requests not accepting cache
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_4", 0)
    ';

    echo_location_async '/collapsed';
    echo_sleep 0.05;
    echo_location_async '/collapsed';
}
location /collapsed {
    content_by_lua '
        ledge:run()'
    ;
}
location /__ledge_origin { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_4", 1))
        ngx.sleep(0.1)
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 5a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 5b: Concurrent COLD requests, response no longer cacheable
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_5", 0)
    ';

    echo_location_async '/collapsed';
    echo_sleep 0.05;
    echo_location_async '/collapsed';
}
location /collapsed {
    content_by_lua '
        ledge:run()'
    ;
}
location /__ledge_origin { 
    content_by_lua '
        ngx.header["Cache-Control"] = "no-cache"
        ngx.say("OK " .. ngx.shared.test:incr("test_5", 1))
        ngx.sleep(0.1)
    ';
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 6: Concurrent SUBZERO requests
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_6", 0)
    ';

    echo_location_async '/collapsed_6';
    echo_sleep 0.05;
    echo_location_async '/collapsed_6';
}
location /collapsed_6 {
    content_by_lua '
        ledge:run()'
    ;
}
location /__ledge_origin { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_6", 1))
        ngx.sleep(0.1)
    ';
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2
