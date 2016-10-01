use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) + 3;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua_block {
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
        ledge:run_workers()
    }
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-while-revalidate=60"
        end)
        ledge:run()
    }
}
location /stale {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-while-revalidate=60"
        ngx.say("TEST 1")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_prx
--- response_body
TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 2: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
        local hdr = ngx.req.get_headers()
        ngx.say("Authorization: ",hdr["Authorization"])
        ngx.say("Cookie: ",hdr["Cookie"])
    }
}
--- request
GET /stale_prx
--- more_headers
Authorization: foobar
Cookie: baz=qux
--- response_body
TEST 1
--- response_headers_like
X-Cache: HIT from .*
--- wait: 3
--- no_error_log
[error]


=== TEST 3: Cache has been revalidated
--- http_config eval: $::HttpConfig
--- config
location /stale_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_main {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    }
}
--- request
GET /stale_prx
--- response_body
TEST 2
Authorization: foobar
Cookie: baz=qux
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
