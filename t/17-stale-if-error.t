use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) - 5;

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
=== TEST 1: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /stale_if_error_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 1a: Serve from cache on error
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /stale_if_error_prx
--- response_body
OK
--- response_headers_like
X-Cache: HIT from .*
Warning: 112 .*
--- no_error_log
[error]


=== TEST 1b: Serve from cache on error with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        }
    }
    location /stale_if_error {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /stale_if_error_prx
--- response_body
OK
--- response_headers_like
X-Cache: HIT from .*
Warning: 112 .*
--- no_error_log
[error]


=== Test 2: Prime Cache with expired content
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                res.header["Cache-Control"] = "max-age=0"
            end)
            ledge:run()
        }
    }
    location /stale_if_error_2 {
        more_set_headers "Cache-Control public, max-age=600";
        echo "TEST 2";
    }
--- request
GET /stale_if_error_2_prx
--- response_body
TEST 2
--- no_error_log
[error]


=== Test 2a: Serve from cache on error with stale warning
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /stale_if_error_2_prx
--- response_headers_like
Warning: 110 .*
--- response_body
TEST 2
--- no_error_log
[error]


=== Test 2b: Pass through error if outside stale window
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /stale_if_error_2_prx
--- error_code: 500
--- no_error_log
[error]


=== Test 2c: Serve from cache on error with stale warning with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        }
    }
    location /stale_if_error_2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /stale_if_error_2_prx
--- response_headers_like
Warning: 110 .*
--- response_body
TEST 2
--- no_error_log
[error]


=== Test 2d: Pass through error if outside stale window with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        }
    }
    location /stale_if_error_2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /stale_if_error_2_prx
--- error_code: 500
--- no_error_log
[error]


=== TEST 3: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                res.header["Cache-Control"] = "max-age=0"
            end)
            ledge:run()
        }
    }
    location /stale_if_error_3 {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /stale_if_error_3_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_body
OK
--- no_error_log
[error]


=== TEST 3a: stale_if_error config should override no-cache
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("stale_if_error", 99999)
            ledge:run()
        }
    }
    location /stale_if_error_3 {
        return 500;
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_3_prx
--- response_body
OK
--- error_code: 200
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]


=== TEST 3b: stale-if-error request header overrides stale_if_error config
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("stale_if_error", 99999)
            ledge:run()
        }
    }
    location /stale_if_error_3 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /stale_if_error_3_prx
--- error_code: 500
--- no_error_log
[error]


=== TEST 4: Prime gzipped response
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_4 {
        gzip on;
        gzip_proxied any;
        gzip_min_length 1;
        gzip_http_version 1.0;
        default_type text/html;
        more_set_headers  "Cache-Control: public, max-age=600";
        more_set_headers  "Content-Type: text/html";
        echo "OK";
    }
--- request
GET /stale_if_error_4_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]
--- wait: 1


=== Test 4b: Serve uncompressed from cache, with a disconnected warning (as content is not yet stale)
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_4 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999, max-age=0
--- request
GET /stale_if_error_4_prx
--- response_headers_like
Warning: 112 .*
X-Cache: HIT from .*
--- response_body
OK
--- no_error_log
[error]


=== TEST 5: Prime Cache with stale-if-error config
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_5 {
        more_set_headers "Cache-Control public, max-age=600, stale-if-error=60";
        echo "OK";
    }
--- request
GET /stale_if_error_5_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 5b: serve stale on error due to response config
--- http_config eval: $::HttpConfig
--- config
    location /stale_if_error_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /stale_if_error_5 {
        return 500;
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_5_prx
--- response_body
OK
--- error_code: 200
--- response_headers_like
X-Cache: HIT from .*
Warning: 112 .*
--- no_error_log
[error]
