use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) - 1;

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
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
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
            res.header["Cache-Control"] = "max-age=0, s-maxage=0"
        end)
        ledge:run()
    ';
}
location /stale {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1
--- no_error_log
[error]


=== TEST 2: Return stale
--- http_config eval: $::HttpConfig
--- config
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
        local hdr = ngx.req.get_headers()
        ngx.say("Authorization: ",hdr["Authorization"])
        ngx.say("Cookie: ",hdr["Cookie"])
    ';
}
--- request
GET /stale_prx
--- more_headers
Authorization: foobar
Cookie: baz=qux
--- response_body
TEST 1
--- wait: 4
--- no_error_log
[error]


=== TEST 3: Cache has been revalidated
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.sleep(3)
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
--- timeout: 6
--- response_body
TEST 2
Authorization: foobar
Cookie: baz=qux
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 4b: Return stale when in offline mode
--- http_config eval: $::HttpConfig
--- config
location /stale_entry {
    echo_location /stale_4_prx;
    echo_flush;
    echo_sleep 3;
}
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
GET /stale_entry
--- wait: 1
--- response_body
TEST 4a
--- no_error_log
[error]


=== TEST 5a: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, s-maxage=0"
        end)
        ledge:run()
    ';
}
location /stale_5 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60"
        ngx.say("TEST 5")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_5_prx
--- response_body
TEST 5
--- no_error_log
[error]


=== TEST 5b: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save_revalidation_data", function(reval_params, reval_headers)
            reval_headers["X-Test"] = ngx.req.get_headers()["X-Test"]
            reval_headers["Cookie"] = ngx.req.get_headers()["Cookie"]
        end)
        ledge:run()
    ';
}
location /stale_5 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5b")
        local hdr = ngx.req.get_headers()
        ngx.say("X-Test: ",hdr["X-Test"])
        ngx.say("Cookie: ",hdr["Cookie"])
    ';
}
--- request
GET /stale_5_prx
--- more_headers
X-Test: foobar
Cookie: baz=qux
--- response_body
TEST 5
--- wait: 1
--- no_error_log
[error]


=== TEST 5c: Cache has been revalidated, custom headers
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /stale_5_prx
--- response_body
TEST 5b
X-Test: foobar
Cookie: baz=qux
--- no_error_log
[error]


=== TEST 6: Reset cache, manually remove revalidation data
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale_reval_params {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 6")
    ';
}
location /stale_reval_params_remove {
    rewrite ^(.*)_remove$ $1 break;
    content_by_lua '
        local redis_mod = require "resty.redis"
        local redis = redis_mod.new()
        redis:connect("127.0.0.1", 6379)
        redis:select(ledge:config_get("redis_database"))
        local key_chain = ledge:cache_key_chain()
        local entity = redis:get(key_chain.key)
        local entity_keys = ledge.entity_keys(key_chain.root .. "::" .. entity)

        redis:del(entity_keys.reval_req_headers)
        redis:del(entity_keys.reval_params)

        redis:set_keepalive()
        ngx.print("REMOVED")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request eval
["GET /stale_reval_params_prx", "GET /stale_reval_params_remove"]
--- response_body eval
["TEST 6", "REMOVED"]
--- no_error_log
[error]


=== TEST 6b: Stale revalidation doesn't choke on missing previous revalidation data.
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_reval_params {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 6: ", ngx.req.get_headers()["Cookie"])
    ';
}
--- more_headers
Cookie: mycookie
--- request
GET /stale_reval_params_prx
--- response_headers_like
Warning: 110 .*
--- error_log
Could not determine expiry for revalidation params. Will fallback to 3600 seconds.
--- response_body: TEST 6
--- wait: 1
--- error_code: 200


=== TEST 6c: Confirm revalidation
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /stale_reval_params_prx
--- no_error_log
[error]
--- response_body: TEST 6: mycookie
--- error_code: 200


=== TEST 7: Prime and immediately expire two keys
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /stale_reval_params {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3700"
        ngx.print("TEST 7: ", ngx.req.get_uri_args()["a"])
    ';
}
--- more_headers
Cache-Control: no-cache
--- request eval
["GET /stale_reval_params_prx?a=1", "GET /stale_reval_params_prx?a=2"]
--- response_body eval
["TEST 7: 1", "TEST 7: 2"]
--- no_error_log
[error]


=== TEST 7b: Concurrent stale revalidation
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /stale_reval_params {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 7 Revalidated: ", ngx.req.get_uri_args()["a"])
    ';
}
--- request eval
["GET /stale_reval_params_prx?a=1", "GET /stale_reval_params_prx?a=2"]
--- no_error_log
[error]
--- response_body eval
["TEST 7: 1", "TEST 7: 2"]
--- wait: 1


=== TEST 7c: Confirm revalidation
--- http_config eval: $::HttpConfig
--- config
location /stale_reval_params_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request eval
["GET /stale_reval_params_prx?a=1", "GET /stale_reval_params_prx?a=2"]
--- no_error_log
[error]
--- response_body eval
["TEST 7 Revalidated: 1", "TEST 7 Revalidated: 2"]
--- no_error_log
[error]
