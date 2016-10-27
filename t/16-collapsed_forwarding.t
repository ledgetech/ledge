use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 1;
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    lua_shared_dict test 1m;
    lua_check_client_abort on;
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('enable_collapsed_forwarding', true)
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
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
=== TEST 1a: Prime cache (collapsed forwardind requires having seen a previously cacheable response)
--- http_config eval: $::HttpConfig
--- config
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /collapsed { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    ';
}
--- request
GET /collapsed_prx
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

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'ledge:run()';
}
location /collapsed { 
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

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("enable_collapsed_forwarding", false)
        ledge:run()'
    ;
}
location /collapsed { 
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

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()'
    ;
}
location /collapsed { 
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

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collpased_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()'
    ;
}
location /collapsed { 
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
location /concurrent_collapsed_6 {
    rewrite_by_lua '
        ngx.shared.test:set("test_6", 0)
    ';

    echo_location_async '/collapsed_6_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_6_prx';
}
location /collapsed_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()'
    ;
}
location /collapsed_6 { 
    content_by_lua '
        ngx.sleep(0.1)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_6", 1))
    ';
}
--- request
GET /concurrent_collapsed_6
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 7a: Prime cache 
--- http_config eval: $::HttpConfig
--- config
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /collapsed { 
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test7a"
        ngx.say("OK")
    ';
}
--- request
GET /collapsed_prx
--- repsonse_body
OK
--- no_error_log
[error]


=== TEST 7b: Concurrent conditional requests which accept cache (i.e. does this work with revalidation)
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua '
        ngx.shared.test:set("test_7", 0)
    ';

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
    echo_sleep 1;
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'ledge:run()';
}
location /collapsed { 
    content_by_lua '
        ngx.sleep(0.1)
        ngx.header["Etag"] = "test7b"
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_7", 1))
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test7b
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 1


=== TEST 9: Allow pending qless jobs to run
--- http_config eval: $::HttpConfig
--- config
location /qless {
    content_by_lua '
        ngx.sleep(5)
        ngx.say("QLESS")
    ';
}
--- request
GET /qless
--- timeout: 6
--- response_body
QLESS
--- no_error_log
[error]
