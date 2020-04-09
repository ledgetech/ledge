use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_lua_config => qq{
    -- For TEST 2
    TEST_NGINX_PORT = $LedgeEnv::nginx_port
});

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler, err = require("ledge").create_handler()
        assert(handler,
            "create_handler() should return postively, got: " .. tostring(err))

        local ok, err = require("ledge.handler").new()
        assert(not ok, "new with empty config should return negatively")
        assert(err == "config table expected",
            "err should be 'config table expected'")

        local handler = require("ledge.handler")
        local ok, err = pcall(function()
            handler.foo = "bar"
        end)
        assert(not ok, "setting unknown field should error")
        assert(string.find(err, "attempt to create new field foo"),
            "err should be 'attempt to create new field foo'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 2: Override config defaults
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = assert(require("ledge").create_handler({
            upstream_host = "example.com",
        }), "create_handler should return positively")

        assert(handler.config.upstream_host == "example.com",
            "upstream_host should be example.com")

        assert(handler.config.upstream_port == TEST_NGINX_PORT,
            "upstream_port should default to " .. TEST_NGINX_PORT)


        -- Change config

        handler.config.upstream_port = 81
        assert(handler.config.upstream_port == 81,
            "upstream_port should be 81")


        -- Unknown config field

        local ok, err = pcall(function()
            handler.config.foo = "bar"
        end)
        assert(not ok, "setting unknown config should error")
        assert(string.find(err, "attempt to create new field foo"),
            "err should be 'attempt to create new field foo'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 3: Call run on simple request without errors
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        assert(require("ledge").create_handler():run(),
            "run should return positively")
    }
}
location /t {
    echo "OK";
}
--- request
GET /t_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 4: Bind / emit
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        function add_header(res)
            res.header["X-Foo"] = "bar"
        end

        -- Bind succeeds
        local ok, err = assert(handler:bind("before_serve", add_header),
            "bind should return positively")

        -- Bad event name
        local ok, err = handler:bind("foo", add_header)
        assert(not ok, "bind should return negatively")
        assert(err == "no such event: foo",
            "err should be 'no such event: foo'")

        -- Bad user event
        handler:bind("before_serve", function(res) error("oops", 2) end)

        handler:run()
    }
}
location /t {
    echo "OK";
}
--- request
GET /t_prx
--- response_body
OK
--- response_headers
X-Foo: bar
--- error_log
no such event: foo
error in user callback for 'before_serve': oops

=== TEST 5: visible hostname
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        -- Defaults to the hostname of the server
        local visible_hostname = string.lower(require("ledge").create_handler().config.visible_hostname)
        local host = string.lower(ngx.var.hostname)
        assert(visible_hostname == host,
            "visible_hostname "..tostring(visible_hostname).." should be "..host)

        -- Test overriding the visible_hostname
        local host = "example.com"
        local visible_hostname = string.lower(require("ledge").create_handler({ visible_hostname = host }).config.visible_hostname)
        assert(visible_hostname == host,
            "visible_hostname should be " .. host)
    }

}
--- request
GET /t
--- no_error_log
[error]

=== TEST 6: read from cache
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()

        -- Set redis and read the cache key
        handler.redis = redis
        handler:cache_key_chain()

        -- Unset redis again
        handler.redis = {}
        local res, err = handler:read_from_cache()
        assert(res == nil and err ~= nil,
            "read_from_cache should error with no redis connections")

        handler.redis = redis
        handler.storage = require("ledge").create_storage_connection(
            handler.config.storage_driver,
            handler.config.storage_driver_config
        )
        local res, err = handler:read_from_cache()
        assert(res and not err, "read_from_cache should return positively")
    }

}
--- request
GET /t
--- no_error_log
[error]


=== TEST 7: Call run with bad redis details
--- http_config eval
qq{
resolver local=on;
lua_package_path "./lib/?.lua;;";

init_by_lua_block {
    if $LedgeEnv::test_coverage == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://redis:0/",
        },
        qless_db = 123,
    })

    require("ledge").set_handler_defaults({
        upstream_host = "$LedgeEnv::nginx_host",
        upstream_port = $LedgeEnv::nginx_port,
        storage_driver_config = {
            redis_connector_params = {
                url = "redis://$LedgeEnv::redis_host:$LedgeEnv::redis_port/$LedgeEnv::redis_database"
            }
        },
    })

    require("ledge.state_machine").set_debug(true)
}
}
--- config
location /t {
    lua_socket_log_errors Off;
    content_by_lua_block {
        local ok, err = require("ledge").create_handler():run()
        assert(ok == nil and err ~= nil,
            "run should return negatively with an error")
        ngx.say("OK")
    }
}
--- request
GET /t
--- response_body
OK
--- no_error_log
[error]

=== TEST 8: save to cache
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()

        handler.redis = redis
        handler:cache_key_chain()
        handler.redis = {}

        local res, err = handler:save_to_cache()
        assert(res == nil and err ~= nil,
            "read_from_cache should error with no response")

        local res, err = handler:fetch_from_origin()
        assert(res == nil and err ~= nil,
            "fetch_from_origin should error with no redis")

        handler.redis = redis
        handler.storage = require("ledge").create_storage_connection(
            handler.config.storage_driver,
            handler.config.storage_driver_config
        )
        local res, err = handler:fetch_from_origin()
        assert(res and not err, "fetch_from_origin should return positively")

        local res, err = handler:save_to_cache(res)
        ngx.log(ngx.DEBUG, res, " ", err)
        assert(res and not err, "save_to_cache should return positively")

        ngx.say("OK")
    }

}
location /t {
    echo "origin";
}
--- request
GET /t_prx
--- no_error_log
[error]
--- response_body
OK

=== TEST 8: save to cache, no body
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        local res, err = handler:save_to_cache()
        assert(res == nil and err ~= nil,
            "read_from_cache should error with no response")

        handler.redis = require("ledge").create_redis_connection()
        handler.storage = require("ledge").create_storage_connection(
            handler.config.storage_driver,
            handler.config.storage_driver_config
        )

        local res, err = handler:fetch_from_origin()
        assert(res and not err, "fetch_from_origin should return positively")

        res.has_body = false

        local res, err = handler:save_to_cache(res)
        ngx.log(ngx.DEBUG, res, " ", err)
        assert(res and not err, "save_to_cache should return positively")

        ngx.say("OK")
    }

}
location /t {
    echo "origin";
}
--- request
GET /t_prx
--- no_error_log
[error]
--- response_body
OK
