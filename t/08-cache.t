use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 7;

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
=== TEST 1: Subzero request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 1")
        ';
    }
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 1


=== TEST 2: Hot request; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        echo "TEST 2";
    }
--- request
GET /cache_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 1


=== TEST 3: No-cache request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 3")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3


=== TEST 3b: No-cache request with extension; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 3b")
        ';
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=1234
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3b


=== TEST 3c: No-store request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 3c")
        ';
    }
--- more_headers
Cache-Control: no-store
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3c
--- no_error_log
[error]


=== TEST 4a: PURGE
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
PURGE /cache_prx
--- wait: 2
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Cold request (expired but known); X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 4")
        ';
    }
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 4


=== TEST 4c: Clean up
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
X-Purge: delete
--- request
PURGE /cache_prx
--- wait: 3
--- error_code: 200
--- no_error_log
[error]


=== TEST 6a: Prime a resource into cache
--- http_config eval: $::HttpConfig
--- config
    location /cache_6_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache_6 {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 6")
        ';
    }
--- request
GET /cache_6_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 6
--- no_error_log
[error]


=== TEST 6b: Revalidate - now the response is a non-cacheable 404.
--- http_config eval: $::HttpConfig
--- config
    location /cache_6_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache_6 {
        content_by_lua '
            ngx.status = 404
            ngx.header["Cache-Control"] = "no-cache"
            ngx.say("TEST 6b")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /cache_6_prx
--- response_headers_like
X-Cache:
--- response_body
TEST 6b
--- error_code: 404
--- no_error_log
[error]


=== TEST 6c: Confirm all keys have been removed (doesn't verify entity gc)
--- http_config eval: $::HttpConfig
--- config
    location /cache_6 {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_database"))
            local key_chain = ledge:cache_key_chain()

            local res, err = redis:keys(key_chain.root .. "*")
            if res then
                ngx.say("Numkeys: ", #res)
            end
        ';
    }
--- request
GET /cache_6
--- response_body
Numkeys: 0
--- no_error_log
[error]


=== TEST 7: only-if-cached should return 504 on cache miss
--- http_config eval: $::HttpConfig
--- config
    location /cache_7_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache_7 {
        content_by_lua '
            ngx.say("TEST 7")
        ';
    }
--- more_headers
Cache-Control: only-if-cached
--- request
GET /cache_7_prx
--- error_code: 504


=== TEST 8: min-fresh reduces calculated ttl
--- http_config eval: $::HttpConfig
--- config
    location /cache_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua '
            ngx.say("TEST 8")
        ';
    }
--- more_headers
Cache-Control: min-fresh=9999
--- request
GET /cache_prx
--- response_body
TEST 8
--- no_error_log
[error]


=== TEST 9a: Prime a 404 response into cache; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_9_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache_9 {
        content_by_lua '
            ngx.status = ngx.HTTP_NOT_FOUND
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 9")
        ';
    }
--- request
GET /cache_9_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 9
--- error_code: 404


=== TEST 9b: Test we still have 404; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
    location /cache_9_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /cache_9_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 9
--- error_code: 404

=== TEST 10: Cache key is the same with nil ngx.var.args and empty string
--- http_config eval: $::HttpConfig
--- config
    location /cache_key {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ngx.say(type(ngx.var.args))
            local key_chain = ledge:cache_key_chain()
            local key1 = key_chain.key

            ngx.req.set_uri_args({})
            ledge:ctx().cache_key = nil
            ledge:ctx().cache_key_chain = nil

            ngx.say(type(ngx.var.args))
            key_chain = ledge:cache_key_chain()
            local key2 = key_chain.key

            if key1 == key2 then
                ngx.say("OK")
            else
                ngx.say("BZZZZT FAiL")
                ngx.say(key1)
                ngx.say(key2)
            end

        ';
    }

--- request
GET /cache_key
--- response_body
nil
string
OK


=== TEST 11: Prime with HEAD into cache (no body); X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_11_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /cache_11 {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
HEAD /cache_11_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
--- error_code: 200
--- no_error_log
[error]


=== TEST 11b: Check HEAD request did not cache
--- http_config eval: $::HttpConfig
--- config
    location /cache_11_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /cache_11 {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
        ';
    }
--- request
HEAD /cache_11_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
--- error_code: 200
--- no_error_log
[error]


=== TEST 12: Prime 301 into cache with no body; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /cache_12 {
        content_by_lua '
            ngx.status = 301
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.header["Location"] = "http://example.com"
        ';
    }
--- request
GET /cache_12_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
--- error_code: 301
--- no_error_log
[error]


=== TEST 12b: Check 301 request cached with no body
--- http_config eval: $::HttpConfig
--- config
    location /cache_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /cache_12_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
--- error_code: 301
--- no_error_log
[error]


=== TEST 13: Subzero request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua_block {
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.header["X-Custom-Hdr"] = "foo"
            ngx.say("TEST 13")
        }
    }
--- request
GET /cache_13_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
X-Custom-Hdr: foo
--- response_body
TEST 13


=== TEST 13b: Forced cache update
--- http_config eval: $::HttpConfig
--- config
    location /cache_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua_block {
            -- Should override ALL headers from TEST 13
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.header["X-Custom-Hdr2"] = "bar"
            ngx.say("TEST 13b")
        }
    }
--- request
GET /cache_13_prx
--- more_headers
Cache-Control: no-cache
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
X-Custom-Hdr2: bar
--- response_body
TEST 13b


=== TEST 13c: Cache hit - Headers are overriden not appended to
--- http_config eval: $::HttpConfig
--- config
    location /cache_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            -- Only return headers from TEST 13b
            ledge:run()
        }
    }

    location /cache {
        content_by_lua_block {
            ngx.say("TEST 13b")
            ngx.log(ngx.ERR, "Never run")
        }
    }
--- request
GET /cache_13_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
X-Custom-Hdr2: bar
--- raw_response_headers_unlike: .*X-Custom-Hdr: foo.*
--- no_error_log
[error]
--- response_body
TEST 13b


=== TEST 14: Cache-Control no-cache=#field and private=#field, drop headers from cache
--- http_config eval: $::HttpConfig
--- config
    location /cache_14_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /cache {
        content_by_lua_block {
            ngx.header["Cache-Control"] = {
                'max-age=3600, private="XTest"',
                'no-cache="X-Test2"'
            }
            ngx.header["XTest"] = "foo"
            ngx.header["X-test2"] = "bar"
            ngx.say("TEST 14")
        }
    }
--- request
GET /cache_14_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
XTest: foo
X-Test2: bar
--- response_body
TEST 14


=== TEST 14b: Cache hit - Headers are not returned from cache
--- http_config eval: $::HttpConfig
--- config
    location /cache_14_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            -- Only return headers from TEST 14b
            ledge:run()
        }
    }

    location /cache {
        content_by_lua_block {
            ngx.say("TEST 14b")
            ngx.log(ngx.ERR, "Never run")
        }
    }
--- request
GET /cache_14_prx
--- response_headers_like
X-Cache: HIT from .*
--- raw_response_headers_unlike: .*(XTest: foo|X-test2: bar).*
--- no_error_log
[error]
--- response_body
TEST 14
