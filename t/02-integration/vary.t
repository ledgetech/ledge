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
lua_check_client_abort on;

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

=== TEST 1: Vary
--- http_config eval: $::HttpConfig
--- config
location /vary_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 1: ", ngx.req.get_headers()["X-Test"])
    }
}
--- request eval
["GET /vary_prx", "GET /vary_prx", "GET /vary_prx", "GET /vary_prx"]
--- more_headers eval
[
"X-Test: testval",
"X-Test: anotherval",
"",
"X-Test: testval",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
]
--- response_body eval
[
"TEST 1: testval",
"TEST 1: anotherval",
"TEST 1: nil",
"TEST 1: testval",
]
--- no_error_log
[error]

=== TEST 2: Vary change
--- http_config eval: $::HttpConfig
--- config
location /vary_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test2"
        ngx.print("TEST 2: ", ngx.req.get_headers()["X-Test2"], " ", ngx.req.get_headers()["X-Test"])
    }
}
--- request eval
["GET /vary_prx", "GET /vary_prx", "GET /vary_prx", "GET /vary_prx"]
--- more_headers eval
[
"X-Test: testval
Cache-Control: no-cache",

"X-Test2: newval",
"",

"X-Test: testval
X-Test2: newval",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
"X-Cache: HIT from .*",
]
--- response_body eval
[
"TEST 2: nil testval",
"TEST 2: newval nil",
"TEST 2: nil testval",
"TEST 2: newval nil",
]
--- no_error_log
[error]


=== TEST 3: Cache update changes 1 representation
--- http_config eval: $::HttpConfig
--- config
location /vary3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 3: ", ngx.req.get_headers()["X-Test"])
    }
}
--- request eval
["GET /vary3_prx", "GET /vary3_prx", "GET /vary3_prx", "GET /vary3_prx"]
--- more_headers eval
[
"X-Test: testval",
"X-Test: value2",

"X-Test: testval
Cache-Control: no-cache",

"X-Test: value2",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
]
--- response_body eval
[
"TEST 3: testval",
"TEST 3: value2",
"TEST 3: testval",
"TEST 3: value2",
]
--- no_error_log
[error]


=== TEST 4: Missing keys are cleaned from repset
--- http_config eval: $::HttpConfig
--- config
location /check {
    rewrite ^ /vary break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local res, err = redis:smembers(handler:cache_key_chain().repset)

        for _, v in ipairs(res) do
            assert(v ~= "foobar", "Key should have been cleaned")
        end
        ngx.print("OK")
    }
}
location /vary_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local ok, err = redis:sadd(handler:cache_key_chain().repset, "foobar")
        handler:run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 4")
    }
}
--- request eval
["GET /vary_prx", "GET /check"]
--- more_headers eval
["Cache-Control: no-cache",""]
--- response_body eval
[
"TEST 4",
"OK"
]
--- no_error_log
[error]


=== TEST 5: Repset TTL maintained
--- http_config eval: $::HttpConfig
--- config
location = /check {
    rewrite ^ /vary5 break;

    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis

        local repset_ttl, err = redis:ttl(handler:cache_key_chain().repset)
        if err then ngx.log(ngx.ERR, err) end

        local vary_ttl, err = redis:ttl(handler:cache_key_chain().vary)
        if err then ngx.log(ngx.ERR, err) end

        local count = ngx.shared.ledge_test:get("test5")

        if count < 3 then
            if (repset_ttl - handler.config.keep_cache_for) <= 300
                or (vary_ttl - handler.config.keep_cache_for) <= 300 then
                ngx.print("FAIL")
              ngx.log(ngx.ERR,
                        (repset_ttl - handler.config.keep_cache_for),
                        " ",
                        (vary_ttl - handler.config.keep_cache_for)
                    )
            else
                ngx.print("OK")
            end
        else

            if (repset_ttl - handler.config.keep_cache_for) < 7200
                or (vary_ttl - handler.config.keep_cache_for) < 7200 then
                ngx.print("FAIL 2")
                ngx.log(ngx.ERR,
                        (repset_ttl - handler.config.keep_cache_for),
                        " ",
                        (vary_ttl - handler.config.keep_cache_for)
                    )
            else
                ngx.print("OK")
            end
        end
    }
}
location /vary5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        local incr = ngx.shared.ledge_test:incr("test5", 1, 0)
        if incr == 1 then
            ngx.header["Cache-Control"] = "max-age=3600"
        elseif incr == 3 then
            ngx.header["Cache-Control"] = "max-age=7200"
        else
            ngx.header["Cache-Control"] = "max-age=300"
        end
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 5")
    }
}
--- request eval
["GET /vary5_prx", "GET /vary5_prx", "GET /check", "GET /vary5_prx", "GET /check"]
--- more_headers eval
[
"Cache-Control: no-cache",
"Cache-Control: no-cache",
"",
"Cache-Control: no-cache",
"",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: MISS from .*",
"",
"X-Cache: MISS from .*",
"",
]
--- response_body eval
[
"TEST 5",
"TEST 5",
"OK",
"TEST 5",
"OK",
]
--- no_error_log
[error]


=== TEST 6: Vary - case insensitive
--- http_config eval: $::HttpConfig
--- config
location /vary6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 6: ", ngx.req.get_headers()["X-Test"])
    }
}
--- request eval
["GET /vary6_prx", "GET /vary6_prx", "GET /vary6_prx"]
--- more_headers eval
[
"X-Test: testval",
"X-test: TestVAL",
"X-teSt: foobar",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
"X-Cache: MISS from .*",
]
--- response_body eval
[
"TEST 6: testval",
"TEST 6: testval",
"TEST 6: foobar",

]
--- no_error_log
[error]
