use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

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
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_NORMAL
        }):run()
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
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
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


=== TEST 2a: ORIGIN_MODE_AVOID (max-age=0 request)
--- http_config eval: $::HttpConfig
--- config
location /origin_mode_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
    }
}
--- more_headers
Cache-Control: max-age=0
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
        local handler = require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        })

        handler:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0"
        end)
        handler:run()
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
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_BYPASS
        }):run()
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_BYPASS
        }):run()
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_bypass_prx
--- error_code: 503
--- no_error_log
[error]
