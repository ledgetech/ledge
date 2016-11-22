use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 53;

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
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_if_error_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-if-error=60"
        ngx.say("TEST 1")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_1_prx
--- response_body
TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 1b: Assert standard non-stale behaviours are unaffected.
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /stale_if_error_1 {
    return 500;
}
--- more_headers eval
["Cache-Control: no-cache", "Cache-Control: no-store", "Pragma: no-cache", ""]
--- request eval
["GET /stale_if_error_1_prx", "GET /stale_if_error_1_prx", "GET /stale_if_error_1_prx", "GET /stale_if_error_1_prx"]
--- error_code eval
[500, 500, 500, 200]
--- raw_response_headers_unlike eval
["Warning: .*", "Warning: .*", "Warning: .*", "Warning: .*"]
--- no_error_log
[error]


=== TEST 2: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-if-error=60"
        end)
        ledge:run()
    }
}
location /stale_if_error_2 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-if-error=60"
        ngx.print("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_2_prx
--- response_body: TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- wait: 2
--- no_error_log
[error]


=== TEST 2b: Request doesn't accept stale, for different reasons
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
--- more_headers eval
["Cache-Control: min-fresh=5", "Cache-Control: max-age=1", "Cache-Control: max-stale=1"]
--- request eval
["GET /stale_if_error_2_prx", "GET /stale_if_error_2_prx", "GET /stale_if_error_2_prx"]
--- error_code eval
[500, 500, 500]
--- raw_response_headers_unlike eval
["Warning: .*", "Warning: .*", "Warning: .*"]
--- no_error_log
[error]


=== TEST 2c: Request accepts stale
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
--- more_headers eval
["Cache-Control: max-age=99999", ""]
--- request eval
["GET /stale_if_error_2_prx", "GET /stale_if_error_2_prx"]
--- response_body eval
["TEST 2", "TEST 2"]
--- response_headers_like eval
["X-Cache: HIT from .*", "X-Cache: HIT from .*"]
--- raw_response_headers_like eval
["Warning: 112 .*", "Warning: 112 .*"]
--- no_error_log
[error]


=== TEST 4: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-if-error=60, must-revalidate"
        end)
        ledge:run()
    }
}
location /stale_if_error_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-if-error=60, must-revalidate"
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_4_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 4b: Response cannot be served stale (must-revalidate)
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
--- request
GET /stale_if_error_4_prx
--- error_code: 500
--- raw_response_headers_unlike
Warning: .*
--- no_error_log
[error]


=== TEST 4c: Prime cache (with valid stale config + proxy-revalidate) and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            res.header["Cache-Control"] = "max-age=0, s-maxage=0, stale-if-error=60, proxy-revalidate"
        end)
        ledge:run()
    }
}
location /stale_if_error_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, s-maxage=60, stale-if-error=60, proxy-revalidate"
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_if_error_4_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 4d: Response cannot be served stale (proxy-revalidate)
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
--- request
GET /stale_if_error_4_prx
--- error_code: 500
--- raw_response_headers_unlike
Warning: .*
--- no_error_log
[error]
