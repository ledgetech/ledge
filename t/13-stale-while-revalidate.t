use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 123;

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
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("TEST 1")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_1_prx
--- response_body
TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 1b: Assert standard non-stale behaviours are unaffected.
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_1 {
    content_by_lua_block {
        if not ledge.req then ledge.req = 1 end

        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.print("ORIGIN: ", ledge.req)

        ledge.req = ledge.req + 1
    }
}
--- more_headers eval
["Cache-Control: no-cache", "Cache-Control: no-store", "Pragma: no-cache", ""]
--- request eval
["GET /stale_1_prx", "GET /stale_1_prx", "GET /stale_1_prx", "GET /stale_1_prx"]
--- response_body eval
["ORIGIN: 1", "ORIGIN: 2", "ORIGIN: 3", "ORIGIN: 3"]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: MISS from .*", "X-Cache: MISS from .*", "X-Cache: HIT from .*"]
--- raw_response_headers_unlike eval
["Warning: .*", "Warning: .*", "Warning: .*", "Warning: .*"]
--- no_error_log
[error]


=== TEST 2: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_2 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_2_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- wait: 1
--- no_error_log
[error]


=== TEST 2b: Request doesn't accept stale, for different reasons
--- http_config eval: $::HttpConfig
--- config
location /stale_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_2 {
    content_by_lua_block {
        if not ledge.req then ledge.req = 1 end

        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.print("ORIGIN: ", ledge.req)

        ledge.req = ledge.req + 1
    }
}
--- more_headers eval
["Cache-Control: min-fresh=5", "Cache-Control: max-age=1", "Cache-Control: max-stale=1"]
--- request eval
["GET /stale_2_prx", "GET /stale_2_prx", "GET /stale_2_prx"]
--- response_body eval
["ORIGIN: 1", "ORIGIN: 2", "ORIGIN: 3"]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: MISS from .*", "X-Cache: MISS from .*"]
--- raw_response_headers_unlike eval
["Warning: .*", "Warning: .*", "Warning: .*"]
--- no_error_log
[error]
--- wait: 2


=== TEST 3: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_3 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.print("TEST 3")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_3_prx
--- response_body: TEST 3
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 3b: Request accepts stale
--- http_config eval: $::HttpConfig
--- config
location /stale_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_3 {
    content_by_lua_block {
        ngx.print("ORIGIN")
    }
}
--- more_headers eval
["Cache-Control: max-age=99999", "Cache-Control: max-stale=99999", ""]
--- request eval
["GET /stale_3_prx", "GET /stale_3_prx", "GET /stale_3_prx"]
--- response_body eval
["TEST 3", "TEST 3", "TEST 3"]
--- response_headers_like eval
["X-Cache: HIT from .*", "X-Cache: HIT from .*", "X-Cache: HIT from .*"]
--- raw_response_headers_like eval
["Warning: 110 .*", "Warning: 110 .*", "Warning: 110 .*"]
--- no_error_log
[error]


=== TEST 3c: Let revalidations finish to prevent errors
--- http_config eval: $::HttpConfig
--- config
location /stale_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_3 {
    content_by_lua_block {
        ngx.print("ORIGIN")
    }
}
--- request
GET /stale_3_prx
--- response_body: TEST 3
--- wait: 1
--- no_error_log
[error]


=== TEST 4: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60, must-revalidate"
        end)
        ledge:run()
    }
}
location /stale_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60, must-revalidate"
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_4_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- wait: 1
--- no_error_log
[error]


=== TEST 4b: Response cannot be served stale (must-revalidate)
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("ORIGIN")
    }
}
--- request
GET /stale_4_prx
--- response_body
ORIGIN
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike
Warning: .*
--- no_error_log
[error]


=== TEST 4c: Prime cache (with valid stale config + proxy-revalidate) and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60, proxy-revalidate"
        end)
        ledge:run()
    }
}
location /stale_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60, proxy-revalidate"
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_4_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- wait: 1
--- no_error_log
[error]


=== TEST 4d: Response cannot be served stale (proxy-revalidate)
--- http_config eval: $::HttpConfig
--- config
location /stale_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("ORIGIN")
    }
}
--- request
GET /stale_4_prx
--- response_body
ORIGIN
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike
Warning: .*
--- no_error_log
[error]


=== TEST 5a: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_5 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("TEST 5")
    }
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
    content_by_lua_block {
        ledge:bind("before_save_revalidation_data", function(reval_params, reval_headers)
            reval_headers["X-Test"] = ngx.req.get_headers()["X-Test"]
            reval_headers["Cookie"] = ngx.req.get_headers()["Cookie"]
        end)
        ledge:run()
    }
}
location /stale_5 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5b")
        local hdr = ngx.req.get_headers()
        ngx.say("X-Test: ",hdr["X-Test"])
        ngx.say("Cookie: ",hdr["Cookie"])
    }
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
    content_by_lua_block {
        ledge:run()
    }
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
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_reval_params {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=60"
        ngx.print("TEST 6")
    }
}
location /stale_reval_params_remove {
    rewrite ^(.*)_remove$ $1 break;
    content_by_lua_block {
        local redis_mod = require "resty.redis"
        local redis = redis_mod.new()
        redis:connect("127.0.0.1", 6379)
        redis:select(ledge:config_get("redis_database"))
        local key_chain = ledge:cache_key_chain()

        redis:del(key_chain.reval_req_headers)
        redis:del(key_chain.reval_params)

        redis:set_keepalive()
        ngx.print("REMOVED")
    }
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
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_reval_params {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=60"
        ngx.print("TEST 6: ", ngx.req.get_headers()["Cookie"])
    }
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
    content_by_lua_block {
        ledge:run()
    }
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
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale_reval_params {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3700, stale-while-revalidate=60"
        ngx.print("TEST 7: ", ngx.req.get_uri_args()["a"])
    }
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
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_reval_params {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=60"
        ngx.print("TEST 7 Revalidated: ", ngx.req.get_uri_args()["a"])
    }
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
    content_by_lua_block {
        ledge:run()
    }
}
--- request eval
["GET /stale_reval_params_prx?a=1", "GET /stale_reval_params_prx?a=2"]
--- no_error_log
[error]
--- response_body eval
["TEST 7 Revalidated: 1", "TEST 7 Revalidated: 2"]
--- no_error_log
[error]
