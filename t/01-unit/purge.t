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
=== TEST 1: create_purge_response
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local cjson_decode = require("cjson").decode

        local create_purge_response = assert(
            require("ledge.purge").create_purge_response,
            "module should load without errors"
        )

        local json, err = create_purge_response("invalidate", "purged")
        local data = cjson_decode(json)

        assert(not err, "err should be nil")

        assert(data.purge_mode == "invalidate",
            "purge mode should be invalidate")

        assert(data.result == "purged",
            "result should be purged")

        assert(not data.qless_job, "qless_job should be nil")


        local json, err = create_purge_response("revalidate", "scheduled", {
            jid = "12345",
        })
        local data = cjson_decode(json)

        assert(not err, "err should be nil")

        assert(data.qless_job.jid == "12345",
            "qless_job.jid should be '12345'")


        local json, err = create_purge_response(function() end)
        assert(err == "Cannot serialise function: type not supported",
            "error should be 'Cannot serialise function: type not supported")
    }
}
--- request
GET /t
--- no_error_log
[error]
