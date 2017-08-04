use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = TEST_NGINX_PORT,
    })

    require("ledge.state_machine").set_debug(true)
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Cache key is the same with nil ngx.var.args and empty string
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local key_chain = require("ledge").create_handler():cache_key_chain()
        local key1 = key_chain.main

        ngx.req.set_uri_args({})

        key_chain = require("ledge").create_handler():cache_key_chain()
        local key2 = key_chain.main

        assert(key1 == key2, "key1 should equal key2")
    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 2: Custom cache key spec
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        assert(handler:cache_key() == "ledge:cache:http:localhost:1984:/t:a=1",
            "cache_key should be ledge:cache:http:localhost:1984:/t:a=1")

        local handler = require("ledge").create_handler({
            cache_key_spec = {
                "scheme",
                "host",
                "port",
                "uri",
                "args",
            }
        })

        assert(handler:cache_key() == "ledge:cache:http:localhost:1984:/t:a=1",
            "cache_key should be ledge:cache:http:localhost:1984:/t:a=1")

        local handler = require("ledge").create_handler({
            cache_key_spec = {
                "host",
                "uri",
            }
        })

        assert(handler:cache_key() == "ledge:cache:localhost:/t",
            "cache_key should be ledge:cache:localhost:/t")


        local handler = require("ledge").create_handler({
            cache_key_spec = {
                "host",
                "uri",
                function() return "hello" end,
            }
        })

        assert(handler:cache_key() == "ledge:cache:localhost:/t:hello",
            "cache_key should be ledge:cache:localhost:/t:hello")
    }
}

--- request
GET /t?a=1
--- no_error_log
[error]


=== TEST 3: Errors in cache key spec functions
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            cache_key_spec = {
                "host",
                "uri",
                function() return 123 end,
            }
        })

        assert(handler:cache_key() == "ledge:cache:localhost:/t",
            "cache_key should be ledge:cache:localhost:/t")


        local handler = require("ledge").create_handler({
            cache_key_spec = {
                "host",
                "uri",
                function() return foo() end,
            }
        })

        assert(handler:cache_key() == "ledge:cache:localhost:/t",
            "cache_key should be ledge:cache:localhost:/t")
    }
}

--- request
GET /t?a=2
--- error_log
functions supplied to cache_key_spec must return a string
error in function supplied to cache_key_spec


=== TEST 4: URI args are sorted (normalised)
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        ngx.print(handler:cache_key())
    }
}
--- request eval
[
    "GET /t",
    "GET /t?a=1",
    "GET /t?aba=1&aab=2",
    "GET /t?a=1&b=2&c=3",
    "GET /t?b=2&a=1&c=3",
    "GET /t?c=3&a=1&b=2",
    "GET /t?c=3&b&a=1",
    "GET /t?c=3&b=&a=1",
    "GET /t?c=3&b=2&a=1&b=4",
]
--- response_body eval
[
    "ledge:cache:http:localhost:1984:/t:",
    "ledge:cache:http:localhost:1984:/t:a=1",
    "ledge:cache:http:localhost:1984:/t:aab=2&aba=1",
    "ledge:cache:http:localhost:1984:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:1984:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:1984:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:1984:/t:a=1&b&c=3",
    "ledge:cache:http:localhost:1984:/t:a=1&b=&c=3",
    "ledge:cache:http:localhost:1984:/t:a=1&b=2&b=4&c=3",
]
--- no_error_log
[error]


=== TEST 5: Max URI args
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            max_uri_args = 2,
        })
        ngx.print(handler:cache_key())
    }
}
--- request eval
[
    "GET /t",
    "GET /t?a=1",
    "GET /t?b=2&a=1",
    "GET /t?c=3&b=2&a=1",
]
--- response_body eval
[
    "ledge:cache:http:localhost:1984:/t:",
    "ledge:cache:http:localhost:1984:/t:a=1",
    "ledge:cache:http:localhost:1984:/t:a=1&b=2",
    "ledge:cache:http:localhost:1984:/t:b=2&c=3",
]
--- no_error_log
[error]


=== TEST 6: Wildcard purge URIs
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        ngx.print(handler:cache_key())
    }
}
--- request eval
[
    "PURGE /t*",
    "PURGE /t?*",
    "PURGE /t?a=1*",
    "PURGE /t?a=*",
]
--- response_body eval
[
    "ledge:cache:http:localhost:1984:/t*:*",
    "ledge:cache:http:localhost:1984:/t:*",
    "ledge:cache:http:localhost:1984:/t:a=1*",
    "ledge:cache:http:localhost:1984:/t:a=*",
]
--- no_error_log
[error]
