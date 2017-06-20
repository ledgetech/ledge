use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_check_client_abort On;

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
        },
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
=== TEST 1: before_serve (add response header)
--- http_config eval: $::HttpConfig
--- config
location /events_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            res.header["X-Modified"] = "Modified"
        end)
        handler:run()
    }
}
location /events_1 {
    echo "ORIGIN";
}
--- request
GET /events_1_prx
--- error_code: 200
--- response_headers
X-Modified: Modified
--- no_error_log
[error]


=== TEST 2: before_upstream_request (modify request params)
--- http_config eval: $::HttpConfig
--- config
location /events_2 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_upstream_request", function(params)
            params.path = "/modified"
        end)
        handler:run()
    }
}
location /modified {
    echo "ORIGIN";
}
--- request
GET /events_2
--- error_code: 200
--- response_body
ORIGIN
--- no_error_log
[error]


=== TEST 2b: As above but using a combination of default and handler bind
--- http_config eval: $::HttpConfig
--- config
location /events_2 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge = require("ledge")

        ledge.bind("before_upstream_request", function(req_params)
            req_params.headers["X-Foo"] = "bar"
        end)

        local handler = require("ledge").create_handler()

        handler:bind("before_upstream_request", function(req_params)
            req_params.path = "/modified"
        end)

        handler:run()
    }
}
location /modified {
    content_by_lua_block {
        ngx.say(ngx.req.get_headers()["X-Foo"])
        ngx.say("ORIGIN");
    }
}
--- request
GET /events_2
--- error_code: 200
--- response_body
bar
ORIGIN
--- no_error_log
[error]
