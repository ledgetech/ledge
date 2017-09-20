use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_shared_dict test 1m;
lua_check_client_abort on;

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
=== TEST 1a: Prime cache (collapsed forwardind requires having seen a previously cacheable response)
--- http_config eval: $::HttpConfig
--- config
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- request
GET /collapsed_prx
--- repsonse_body
OK
--- no_error_log
[error]


=== TEST 1b: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 2: Concurrent COLD requests accepting cache
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_2", 0)
    }

    echo_location_async "/collapsed_prx";
    echo_sleep 0.05;
    echo_location_async "/collapsed_prx";
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.sleep(0.1)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_2", 1))
    }
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 1


=== TEST 3a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 3b: Concurrent COLD requests with collapsing turned off
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_3", 0)
    }

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = false,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_3", 1))
        ngx.sleep(0.1)
    }
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 4a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Concurrent COLD requests not accepting cache
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_4", 0)
    }

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_4", 1))
        ngx.sleep(0.1)
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 5a: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
PURGE /collapsed
--- error_code: 200
--- no_error_log
[error]


=== TEST 5b: Concurrent COLD requests, response no longer cacheable
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_5", 0)
    }

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
}
location /collpased_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "no-cache"
        ngx.say("OK " .. ngx.shared.test:incr("test_5", 1))
        ngx.sleep(0.1)
    }
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 6: Concurrent SUBZERO requests
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed_6 {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_6", 0)
    }

    echo_location_async '/collapsed_6_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_6_prx';
}
location /collapsed_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed_6 {
    content_by_lua_block {
        ngx.sleep(0.1)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_6", 1))
    }
}
--- request
GET /concurrent_collapsed_6
--- error_code: 200
--- response_body
OK 1
OK 2


=== TEST 7a: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test7a"
        ngx.say("OK")
    }
}
--- request
GET /collapsed_prx
--- repsonse_body
OK
--- no_error_log
[error]


=== TEST 7b: Concurrent conditional requests which accept cache
    (i.e. does this work with revalidation)
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_7", 0)
    }

    echo_location_async '/collapsed_prx';
    echo_sleep 0.05;
    echo_location_async '/collapsed_prx';
    echo_sleep 1;
}
location /collapsed_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.sleep(0.1)
        ngx.header["Etag"] = "test7b"
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_7", 1))
    }
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test7b
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body

=== TEST 8a: Prime cache (collapsed forwardind requires having seen a previously cacheable response)
--- http_config eval: $::HttpConfig
--- config
location /collapsed8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /collapsed8 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- request eval
["GET /collapsed8_prx", "PURGE /collapsed8_prx"]
--- no_error_log
[error]


=== TEST 8b: Collapse window timed out
--- http_config eval: $::HttpConfig
--- config
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_8", 0)
    }

    echo_location_async "/collapsed8_prx";
    echo_sleep 0.05;
    echo_location_async "/collapsed8_prx";
}
location /collapsed8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
            collapsed_forwarding_window = 500, -- (ms)
        }):run()
    }
}
location /collapsed8 {
    content_by_lua_block {
        ngx.sleep(0.8)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK " .. ngx.shared.test:incr("test_8", 1))
    }
}
--- request
GET /concurrent_collapsed
--- error_code: 200
--- response_body
OK 1
OK 2

=== TEST 9: Collapsing with vary
--- http_config eval: $::HttpConfig
--- config
location /prime {
    rewrite ^ /collapsed9 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /concurrent_collapsed {
    rewrite_by_lua_block {
        ngx.shared.test:set("test_9", 0)
    }

    echo_location_async "/collapsed9_prx";
    echo_sleep 0.05;
    echo_location_async "/collapsed9_prx";
}
location /collapsed9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.sleep(0.1)
        local counter = ngx.shared.test:incr("test_9", 1)
        ngx.header["Vary"] = "X-Test"
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("OK " .. tostring(counter))
    }
}
--- request eval
[
"GET /prime", "PURGE /prime",
"GET /concurrent_collapsed"
]
--- error_code eval
[200, 200, 200]
--- response_body_like eval
[
"OK nil", ".+",
"OK 1OK 1"
]

=== TEST 10: Collapsing with vary - change in spec
--- http_config eval: $::HttpConfig
--- config
location /prime {
    rewrite ^ /collapsed10 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            enable_collapsed_forwarding = false,
        }):run()
    }
}
location /concurrent_collapsed {
    echo_location_async "/collapsed10_prx";
    echo_sleep 0.05;
    echo_location_async "/collapsed10_prx";
}
location /collapsed10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler({
            enable_collapsed_forwarding = true,
        }):run()
    }
}
location /collapsed {
    content_by_lua_block {
        ngx.sleep(0.1)
        local counter = ngx.shared.test:incr("test_10", 1, 0)
        if counter == 1 then
            ngx.header["Vary"] = "X-Test" -- Prime with this
        else
            ngx.header["Vary"] = "X-Test2"
        end
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("OK " .. tostring(counter))
    }
}
--- request eval
[
"GET /prime", "PURGE /prime",
"GET /concurrent_collapsed"
]
--- more_headers eval
[
"X-Test: Foo","X-Test: Foo",
"X-Test: Foo",
]
--- error_code eval
[200, 200, 200]
--- response_body_like eval
[
"OK 1", ".+",
"OK 2OK 2"
]

