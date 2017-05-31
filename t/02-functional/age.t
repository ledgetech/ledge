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
        jit.off()
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
    if $ENV{TEST_COVERAGE} == 1 then
        jit.off()
    end
    require("ledge").create_worker():run()
}

};

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: No calculated Age header on cache MISS.
--- http_config eval: $::HttpConfig
--- config
location /age_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
    }
}
location /age {
    more_set_headers "Cache-Control public, max-age=600";
    echo "OK";
}
--- request
GET /age_prx
--- response_headers
Age:
--- no_error_log
[error]


=== TEST 2: Age header on cache HIT
--- http_config eval: $::HttpConfig
--- config
location /age_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
    }
}
location /age {
    more_set_headers "Cache-Control public, max-age=600";
    echo "OK";
}
--- request
GET /age_prx
--- response_headers_like
Age: \d+
--- no_error_log
[error]
