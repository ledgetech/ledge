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
        local incr = ngx.shared.ledge_test:incr("test6", 1, 0)
        if incr == 1 then
            ngx.header["Vary"] = "X-Test"
        elseif incr == 2 then
            ngx.header["Vary"] = "X-test"
        else
            ngx.header["Vary"] = "x-Test"
        end
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

=== TEST 7: Vary - sort order
--- http_config eval: $::HttpConfig
--- config
location /vary7_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
}

location /vary {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3700"
        local incr = ngx.shared.ledge_test:incr("test7", 1, 0)
        if incr == 1 then
            -- Prime with 1 order
            ngx.header["Vary"] = "X-Test, X-Test2, X-Test3"
        elseif incr == 2 then
            -- Second request, different order, different values in request
            ngx.header["Vary"] = "X-Test3, X-test, X-test2"
        else
            -- 3rd request, same values as request1, different values in vary
            ngx.header["Vary"] = "X-Test2, X-test3, X-Test"
        end
        ngx.print("TEST 7: ", incr)
    }
}
--- request eval
["GET /vary7_prx", "GET /vary7_prx", "GET /vary7_prx"]
--- more_headers eval
[
"X-Test: abc
X-Test2: 123
X-Test3: xyz
",

"X-Test: abc2
X-Test2: 123b
X-Test3: xyz2
",

"X-Test: abc
X-Test2: 123
X-Test3: xyz
",

]
--- response_headers_like eval
[
"X-Cache: MISS from .*
Vary: X-Test, X-Test2, X-Test3",

"X-Cache: MISS from .*
Vary: X-Test3, X-test, X-test2",

"X-Cache: HIT from .*
Vary: X-Test, X-Test2, X-Test3",
]
--- response_body eval
[
"TEST 7: 1",
"TEST 7: 2",
"TEST 7: 1",
]
--- no_error_log
[error]


=== TEST 8: Vary event hook
--- http_config eval: $::HttpConfig
--- config
location /vary8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        local handler = require("ledge").create_handler()

        handler:bind("before_vary_selection", function(vary_key)
            local x_vary = ngx.req.get_headers()["X-Vary"]
            -- Do nothing if noop set
            if x_vary ~= "noop" then
                vary_key["x-test"] = nil
                vary_key["X-Test2"] = x_vary
            end
            ngx.log(ngx.DEBUG, "Vary Key: ", require("cjson").encode(vary_key))
        end)

        handler:run()
    }
}

location /vary {
    content_by_lua_block {
        local incr = ngx.shared.ledge_test:incr("test8", 1, 0)
        ngx.header["Cache-Control"] = "max-age=3600"
        if ngx.req.get_headers()["X-Vary"] == "noop" then
            ngx.header["Vary"] = "X-Test2"
        else
            ngx.header["Vary"] = "X-Test"
        end
        ngx.print("TEST 8: ", incr)
    }
}
--- request eval
["GET /vary8_prx", "GET /vary8_prx", "GET /vary8_prx", "GET /vary8_prx"]
--- more_headers eval
[
"X-Test: testval
X-Vary: foo",

"X-Test: anotherval
X-Vary: foo",

"X-Test2: bar
X-Vary: noop",

"X-Vary: bar",
]
--- response_headers_like eval
[
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
"X-Cache: MISS from .*",
"X-Cache: HIT from .*",
]
--- response_body eval
[
"TEST 8: 1",
"TEST 8: 1",
"TEST 8: 2",
"TEST 8: 2",
]
--- no_error_log
[error]
