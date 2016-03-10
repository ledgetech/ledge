use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 3; 

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
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
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

    location /cache {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 4")
        ';
    }
--- request
PURGE /cache_prx
--- error_code: 200
--- no_error_log
[error]


=== TEST 4: Cold request (expired but known); X-Cache: MISS
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


=== TEST 6c: Confirm all keys have been removed
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

            ngx.sleep(2) -- Wait for gc

            local res, err = redis:keys(key_chain.root .. "*")
            if res then
                ngx.say("Numkeys: ", #res)
                for i,v in ipairs(res) do
                    ngx.say(v)
                end
            end
        ';
    }
--- request
GET /cache_6
--- timeout: 6
--- response_body
Numkeys: 6
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


=== TEST 13: Allow pending qless jobs to run
--- http_config eval: $::HttpConfig
--- config
location /qless {
    content_by_lua '
        ngx.sleep(5)
        ngx.say("TEST 12")
    ';
}
--- request
GET /qless
--- timeout: 6
--- response_body
TEST 12
--- no_error_log
[error]
