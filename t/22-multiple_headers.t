use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 6;

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
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

run_tests();

__DATA__
=== TEST 1: Multiple cache-control response headers, miss
--- http_config eval: $::HttpConfig
--- config
    location /multiple_cache_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /multiple_cache_headers {
        content_by_lua '
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 1")
        ';
    }
--- request
GET /multiple_cache_headers_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1


=== TEST 1b: Multiple cache-control response headers, hit
--- http_config eval: $::HttpConfig
--- config
    location /multiple_cache_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /multiple_cache_headers {
        content_by_lua '
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 2")
        ';
    }
--- request
GET /multiple_cache_headers_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1
