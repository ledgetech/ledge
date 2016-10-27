use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 1; 

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
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('cache_max_memory', 8 / 1024)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Response larger than cache_max_memory.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /max_memory {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("RESPONSE IS TOO LARGE TEST 1")
    ';
}
--- request
GET /max_memory_prx
--- response_body
RESPONSE IS TOO LARGE TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- error_log
cache item deleted as it is larger than 8 bytes


=== TEST 2: Test we didn't store in previous test.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /max_memory {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
    ';
}
--- request
GET /max_memory_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log


=== TEST 3: Non-chunked response larger than cache_max_memory.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /max_memory_3 {
    chunked_transfer_encoding off;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        local body = "RESPONSE IS TOO LARGE TEST 3\\\n"
        ngx.header["Content-Length"] = string.len(body)
        ngx.print(body)
    ';
}
--- request
GET /max_memory_3_prx
--- response_body
RESPONSE IS TOO LARGE TEST 3
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log


=== TEST 4: Test we didn't store in previous test.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /max_memory_3 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4")
    ';
}
--- request
GET /max_memory_3_prx
--- response_body
TEST 4
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
