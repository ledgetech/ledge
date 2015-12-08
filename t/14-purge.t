use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) - 7;

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
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('keep_cache_for', 0)
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
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- request
GET /purge_cached_prx
--- timeout: 6
--- no_error_log
[error]
--- response_body
TEST 1


=== TEST 2: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        ledge:run()
    ';
}

--- request
PURGE /purge_cached
--- no_error_log
[error]
--- error_code: 200


=== TEST 3: Cache has been purged
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    ';
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 3


=== TEST 4: Purge on unknown key returns 404
--- http_config eval: $::HttpConfig
--- config
location /foobar {
    content_by_lua '
        ledge:run()
    ';
}

--- request
PURGE /foobar
--- no_error_log
--- error_code: 404


=== TEST 5a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 5b: Wildcard Purge
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_cached*
--- no_error_log
[error]
--- error_code: 200


=== TEST 5c: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5c")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5c


=== TEST 5d: Cache has been purged without args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5d")
    ';
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 5d


=== TEST 6a: Purge everything
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_c*
--- error_code: 200
--- no_error_log
[error]


=== TEST 6: Cache keys have been collected by Redis
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        local redis_mod = require "resty.redis"
        local redis = redis_mod.new()
        redis:connect("127.0.0.1", 6379)
        redis:select(ledge:config_get("redis_database"))
        local key_chain = ledge:cache_key_chain()

        ngx.sleep(3)
        local res, err = redis:keys(key_chain.root .. "*")

        ngx.say("keys: ", table.getn(res))
    ';
}
--- request
GET /purge_cached
--- timeout: 6
--- no_error_log
[error]
--- response_body
keys: 0


=== TEST 7a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 7b: Wildcard Purge, mid path (no match due to args)
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_ca*ed
--- no_error_log
[error]
--- error_code: 404


=== TEST 8a: Prime another key - with keep_cache_for set
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_8 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8")
    ';
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8


=== TEST 8b: Wildcard Purge (200)
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8 {
    content_by_lua '
        ledge:config_set("keyspace_scan_count", 1)
        ledge:run()
    ';
}
--- request
PURGE /purge_cached_8*
--- no_error_log
[error]
--- error_code: 200


=== TEST 8c: Wildcard Purge again (404)
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8 {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_cached_8*
--- no_error_log
[error]
--- error_code: 404


=== TEST 8d: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached_8 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8c")
    ';
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8c

