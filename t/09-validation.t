use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 7;

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
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test1"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 100)
        ngx.say("TEST 1")
    ';
}
--- request
GET /validation_prx
--- response_body
TEST 1
--- response_headers_like
X-Cache: MISS from .*


=== TEST 2: Unspecified end-to-end revalidation (max-age=0 + no validator), upstream 200
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test2"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 90)
        ngx.say("TEST 2")
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*


=== TEST 2b: Unspecified end-to-end revalidation (max-age=0 + no validator), upstream 304
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- response_body
TEST 2
--- error_code: 200
--- response_headers_like
X-Cache: MISS from .*


=== TEST 3: Revalidate against cache using IMS in the future. Check we still have headers
with our 304, and no body.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 100))
        ledge:run()
    ';
}
--- request
GET /validation_prx
--- error_code: 304
--- response_headers
Cache-Control: max-age=3600
Etag: test2
--- response_body


=== TEST 3b: Revalidate against cache using IMS in the past. Return 200 fresh cache.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() - 100))
        ledge:run()
    ';
}
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: HIT from .*


=== TEST 4: Revalidate against cache using Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- more_headers
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304
--- response_body


=== TEST 4b: Revalidate against cache using LM and Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 100))
        ledge:run()
    ';
}
--- more_headers
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304
--- response_body


=== TEST 5: Specific end-to-end revalidation using IMS, upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() - 150))
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*


=== TEST 6: Specific end-to-end revalidation using INM (matching), upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304


=== TEST 6b: Specific end-to-end revalidation using INM (not matching), upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test6b
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*


=== TEST 7: Specific end-to-end revalidation using IMS, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() - 150))
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test7"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 70)
        ngx.say("TEST 7")
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 7


=== TEST 8: Specific end-to-end revalidation using INM, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test8"
        ngx.say("TEST 8")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 8
--- response_headers_like
X-Cache: MISS from .*


=== TEST 8b: Unspecified end-to-end revalidation using INM, upstream 200, validators now match (so 304 to client).
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test8b"
        ngx.say("TEST 8b")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test8b
--- request
GET /validation_prx
--- error_code: 304
--- response_body


=== TEST 9: Check revalidation re-saved.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 8b
--- response_headers_like
X-Cache: HIT from .*


=== TEST 9: Validators on a cache miss (should never 304).
--- http_config eval: $::HttpConfig
--- config
location /validation_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation_9 {
    content_by_lua '
        if ngx.req.get_headers()["Cache-Control"] == "max-age=0" and
            ngx.req.get_headers()["If-None-Match"] == "test9" then
            ngx.exit(ngx.HTTP_NOT_MODIFIED)
        else
            ngx.say("TEST 9")
        end
    ';
}
--- more_headers
If-None-Match: test9
--- request
GET /validation_9_prx
--- error_code: 200
--- response_body
TEST 9


=== TEST 10: Re-Validation on an a cache miss using INM. Upstream 200, but valid once cached (so 304 to client).
--- http_config eval: $::HttpConfig
--- config
location /validation10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /validation10 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test10"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 60)
        ngx.say("TEST 10")
    ';
}
--- more_headers
If-None-Match: test10
--- request
GET /validation10_prx
--- error_code: 304
--- response_body


=== TEST 11: Test badly formatted IMS is ignored.
--- http_config eval: $::HttpConfig
--- config
location /validation10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- more_headers
If-Modified-Since: 234qr12411224 
--- request
GET /validation10_prx
--- error_code: 200
--- response_body
TEST 10
--- response_headers_like
X-Cache: HIT from .*


=== TEST 12: Allow pending qless jobs to run
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
