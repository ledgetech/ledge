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
=== TEST 1: Test hop-by-hop headers are not passed on.
--- http_config eval: $::HttpConfig
--- config
location /hop_by_hop_headers_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /hop_by_hop_headers {
    more_set_headers "Cache-Control public, max-age=600";
    more_set_headers "Proxy-Authenticate foo";
    more_set_headers "Upgrade foo";
    echo "OK";
}
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate:
Upgrade:
--- no_error_log
[error]


=== TEST 2: Test hop-by-hop headers were not cached.
--- http_config eval: $::HttpConfig
--- config
location /hop_by_hop_headers_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate:
Upgrade:
--- no_error_log
[error]
