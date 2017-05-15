use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })
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
        assert(require("ledge.handler").new({}),
            "handler.new should return postively")

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

        assert(handler.config.upstream_port == 80,
            "upstream_port should default to 80")


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


=== TEST 3: Run handler
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
--- SKIP: wont work yet
