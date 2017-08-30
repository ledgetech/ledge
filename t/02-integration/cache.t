use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

lua_shared_dict ledge_test 1m;

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    }
}
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 1
--- no_error_log
[error]

=== TEST 1b: Subzero request; X-Cache: MISS is prepended
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["X-Cache"] = "HIT from example.com"
        ngx.say("TEST 1")
    }
}
--- request
GET /cache_prx?append
--- response_headers_like
X-Cache: MISS from .+, HIT from example.com
--- response_body
TEST 1
--- no_error_log
[error]


=== TEST 2: Hot request; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /cache_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 1
--- no_error_log
[error]


=== TEST 3: No-cache request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3
--- no_error_log
[error]


=== TEST 3b: No-cache request with extension; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3b")
    }
}
--- more_headers
Cache-Control: no-cache, stale-if-error=1234
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3b
--- no_error_log
[error]


=== TEST 3c: No-store request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3c")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /cache_prx
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Cold request (expired but known); X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4")
    }
}
--- request
GET /cache_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 4
--- no_error_log
[error]


=== TEST 4c: Clean up
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- more_headers
X-Purge: delete
--- request
PURGE /cache_prx
--- error_code: 200
--- no_error_log
[error]


=== TEST 6a: Prime a resource into cache
--- http_config eval: $::HttpConfig
--- config
location /cache_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_6 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 6")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_6 {
    content_by_lua_block {
        ngx.status = 404
        ngx.header["Cache-Control"] = "no-cache"
        ngx.say("TEST 6b")
    }
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
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local key_chain = handler:cache_key_chain()
        local redis = require("ledge").create_redis_connection()

        local res, err = redis:keys(key_chain.root .. "*")
        if res then
            ngx.say("Numkeys: ", #res)
        end
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_7 {
    content_by_lua_block {
        ngx.say("TEST 7")
    }
}
--- more_headers
Cache-Control: only-if-cached
--- request
GET /cache_7_prx
--- error_code: 504
--- no_error_log
[error]


=== TEST 8: min-fresh reduces calculated ttl
--- http_config eval: $::HttpConfig
--- config
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache {
    content_by_lua_block {
        ngx.say("TEST 8")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_9 {
    content_by_lua_block {
        ngx.status = ngx.HTTP_NOT_FOUND
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9")
    }
}
--- request
GET /cache_9_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 9
--- error_code: 404
--- no_error_log
[error]


=== TEST 9b: Test we still have 404; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
location /cache_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /cache_9_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 9
--- error_code: 404
--- no_error_log
[error]


=== TEST 11: Prime with HEAD into cache (no body); X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
location /cache_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_11 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_11 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_12 {
    content_by_lua_block {
        ngx.status = 301
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Location"] = "http://example.com"
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_13 {
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
--- no_error_log
[error]


=== TEST 13b: Forced cache update
--- http_config eval: $::HttpConfig
--- config
location /cache_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_13 {
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
--- no_error_log
[error]


=== TEST 13c: Cache hit - Headers are overriden not appended to
--- http_config eval: $::HttpConfig
--- config
location /cache_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_13 {
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_14 {
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
--- no_error_log
[error]


=== TEST 14b: Cache hit - Headers are not returned from cache
--- http_config eval: $::HttpConfig
--- config
location /cache_14_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_14 {
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


=== TEST 15a: Prime a resource into cache
--- http_config eval: $::HttpConfig
--- config
location /cache_15_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 1,
        }):run()
    }
}
location /cache_15 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("TEST 15")
    }
}
--- request
GET /cache_15_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 15
--- no_error_log
[error]


=== TEST 15b: Confim all keys exists
--- http_config eval: $::HttpConfig
--- config
location /cache_15_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local key_chain = handler:cache_key_chain()
        local redis = require("ledge").create_redis_connection()

        local res, err = redis:keys(key_chain.root .. "*")
        if res then
            ngx.say("Numkeys: ", #res)
        end

        -- Sleep longer than keep_cache_for, to prove all keys have ttl assigned
        ngx.sleep(3)

        local res, err = redis:keys(key_chain.root .. "*")
        if res then
            ngx.say("Numkeys: ", #res)
        end
    }
}
--- request
GET /cache_15_prx
--- timeout: 5
--- response_body
Numkeys: 5
Numkeys: 5
--- no_error_log
[error]


=== TEST 16: Prime a resource into cache
--- http_config eval: $::HttpConfig
--- config
location /cache_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("TEST 16")
    }
}
--- request
GET /cache_16_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 16
--- no_error_log
[error]

=== TEST 16b: Modified main key aborts transaction and cleans up entity
--- http_config eval: $::HttpConfig
--- config
location /cache_16_check {
    content_by_lua_block {
        local entity_id = ngx.shared.ledge_test:get("entity_id")
        local redis = require("ledge").create_storage_connection()
        local ok, err = redis:exists(entity_id)
        ngx.print(ok, " ", err)
    }
}
location /cache_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            -- Create a new connection
            local redis = require("ledge").create_redis_connection()
            -- Set a new key on the main key
            redis:hset(handler:cache_key_chain().main, "foo", "bar")

            ngx.shared.ledge_test:set("entity_id", res.entity_id)
        end)

        handler:run()
    }
}
location /cache_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.print("TEST 16b")
    }
}
--- request eval
["GET /cache_16_prx", "GET /cache_16_check"]
--- more_headers
Cache-Control: no-cache
--- response_headers_like eval
["X-Cache: MISS from .*", ""]
--- response_body eval
["TEST 16b", "false nil"]
--- wait: 3
--- no_error_log
[error]

=== TEST 16c: Modified main key aborts transaction - HIT
--- http_config eval: $::HttpConfig
--- config
location /cache_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cache_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("TEST 16b")
    }
}
--- request
GET /cache_16_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 16
--- no_error_log
[error]


=== TEST 16d: Partial entry misses
--- http_config eval: $::HttpConfig
--- config
location /cache_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local key_chain = handler:cache_key_chain()
        local redis = require("ledge").create_redis_connection()

        -- Break entities
        redis:del(handler:cache_key_chain().entities)

        handler:run()
    }
}
location /cache_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("TEST 16d")
    }
}
--- request
GET /cache_16_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 16d
--- no_error_log
[error]
