use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 3;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('background_revalidate', true)
        ledge:config_set('max_stale', 99999)
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1


=== TEST 2: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale_entry {
    echo_location /stale_prx;
    echo_sleep 4;
}
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
    ';
}
--- request
GET /stale_entry
--- response_body
TEST 1
--- timeout: 6
--- no_error_log
[error]


=== TEST 3: Cache has been revalidated
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_main {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    ';
}
--- request
GET /stale_prx
--- response_body
TEST 2


=== TEST 4a: Re-prime and expire
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale_4 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4a")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_4_prx
--- response_body
TEST 4a


=== TEST 4b: Return stale when in offline mode
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
        ledge:run()
    ';
}
location /stale_4 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4b")
    ';
}
--- request
GET /stale_4_prx
--- response_body
TEST 4a
--- no_error_log
[error]
