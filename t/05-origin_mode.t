use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 6) - 4;

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
=== TEST 1: ORIGIN_MODE_NORMAL
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_NORMAL)
            ledge:run()
        }
    }
    location /origin_mode {
        content_by_lua_block {
            ngx.header["Cache-Control"] = "public, max-age=60"
            ngx.print("OK")
        }
    }
--- request eval
["GET /origin_mode_prx", "GET /origin_mode_prx"]
--- response_body eval
["OK", "OK"]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: HIT from .*"]
--- no_error_log
[error]


=== TEST 2: ORIGIN_MODE_AVOID (no-cache request)
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_AVOID)
            ledge:run()
        }
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_prx
--- response_body: OK
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]


=== TEST 2b: ORIGIN_MODE_AVOID (expired cache)
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_2b_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_AVOID)
            ledge:bind("before_save", function(res)
                -- immediately expire
                res.header["Cache-Control"] = "max-age=0"
            end)
            ledge:run()
        }
    }
    location /origin_mode_2b {
        content_by_lua_block {
            ngx.header["Cache-Control"] = "public, max-age=60"
            ngx.print("OK")
        }
    }
--- request eval
["GET /origin_mode_2b_prx", "GET /origin_mode_2b_prx"]
--- response_body eval
["OK", "OK"]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: HIT from .*"]
--- no_error_log
[error]


=== TEST 3: ORIGIN_MODE_BYPASS when cached with 112 warning
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
            ledge:run()
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_prx
--- response_headers_like
Warning: 112 .*
--- response_body: OK
--- no_error_log
[error]


=== TEST 4: ORIGIN_MODE_BYPASS when we have nothing
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_bypass_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
            ledge:run()
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_bypass_prx
--- error_code: 503
--- no_error_log
[error]
