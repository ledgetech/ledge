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
        upstream_port = TEST_NGINX_PORT,
    })

    require("ledge.state_machine").set_debug(true)
}

}; # HttpConfig

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


=== TEST 5: Cache key is the same with nil ngx.var.args and empty string
--- http_config eval: $::HttpConfig
--- config
location /cache_key {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local key_chain = require("ledge").create_handler():cache_key_chain()
        local key1 = key_chain.key

        ngx.req.set_uri_args({})

        key_chain = require("ledge").create_handler():cache_key_chain()
        local key2 = key_chain.key

        assert(key1 == key2, "key1 should equal key2")
    }
}

--- request
GET /cache_key
--- no_error_log
[error]
