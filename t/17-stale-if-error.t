use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

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
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector = {
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
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /stale_if_error_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] =
            "max-age=3600, s-maxage=60, stale-if-error=60"
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
        require("ledge").create_handler():run()
    }
}
location /stale_if_error_1 {
    return 500;
}
--- more_headers eval
[
    "Cache-Control: no-cache",
    "Cache-Control: no-store",
    "Pragma: no-cache",
    ""
]
--- request eval
[
    "GET /stale_if_error_1_prx",
    "GET /stale_if_error_1_prx",
    "GET /stale_if_error_1_prx",
    "GET /stale_if_error_1_prx"
]
--- error_code eval
[
    500,
    500,
    500,
    200
]
--- raw_response_headers_unlike eval
[
    "Warning: .*",
    "Warning: .*",
    "Warning: .*",
    "Warning: .*"
]
--- no_error_log
[error]


=== TEST 2: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            res.header["Cache-Control"] =
                "max-age=0, s-maxage=0, stale-if-error=60"
        end)
        handler:run()
    }
}
location /stale_if_error_2 {
    content_by_lua_block {
        ngx.header["Cache-Control"] =
            "max-age=3600, s-maxage=60, stale-if-error=60"
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


=== TEST 2b: Request does not accept stale, for different reasons
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}
location /stale_if_error_2 {
    return 500;
}
--- more_headers eval
[
    "Cache-Control: min-fresh=5",
    "Cache-Control: max-age=1",
    "Cache-Control: max-stale=1"
]
--- request eval
[
    "GET /stale_if_error_2_prx",
    "GET /stale_if_error_2_prx",
    "GET /stale_if_error_2_prx"
]
--- error_code eval
[
    500,
    500,
    500
]
--- raw_response_headers_unlike eval
[
    "Warning: .*",
    "Warning: .*",
    "Warning: .*"
]
--- response_body_unlike eval
[
    "TEST 2",
    "TEST 2",
    "TEST 2",
]
--- no_error_log
[error]


=== TEST 2c: Request accepts stale
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /stale_if_error_2 {
    return 500;
}
--- more_headers eval
[
    "Cache-Control: max-age=99999",
    ""
]
--- request eval
[
    "GET /stale_if_error_2_prx",
    "GET /stale_if_error_2_prx"
]
--- response_body eval
[
    "TEST 2",
    "TEST 2"
]
--- response_headers_like eval
[
    "X-Cache: HIT from .*",
    "X-Cache: HIT from .*"
]
--- raw_response_headers_like eval
[
    "Warning: 112 .*",
    "Warning: 112 .*"
]
--- no_error_log
[error]


=== TEST 4: Prime cache and expire it
--- http_config eval: $::HttpConfig
--- config
location /stale_if_error_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            res.header["Cache-Control"] =
                "max-age=0, s-maxage=0, stale-if-error=60, must-revalidate"
        end)
        handler:run()
    }
}
location /stale_if_error_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] =
            "max-age=3600, s-maxage=60, stale-if-error=60, must-revalidate"
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
        require("ledge").create_handler():run()
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
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            res.header["Cache-Control"] =
                "max-age=0, s-maxage=0, stale-if-error=60, proxy-revalidate"
        end)
        handler:run()
    }
}
location /stale_if_error_4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] =
            "max-age=3600, s-maxage=60, stale-if-error=60, proxy-revalidate"
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
        require("ledge").create_handler():run()
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
