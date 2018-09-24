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
=== TEST 1: Multiple cache-control response headers, miss
--- http_config eval: $::HttpConfig
--- config
    location /multiple_cache_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }

    location /multiple_cache_headers {
        content_by_lua_block {
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 1")
        }
    }
--- request
GET /multiple_cache_headers_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1


=== TEST 1b: Multiple cache-control response headers, hit
--- http_config eval: $::HttpConfig
--- config
    location /multiple_cache_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }

    location /multiple_cache_headers {
        content_by_lua_block {
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 2")
        }
    }
--- request
GET /multiple_cache_headers_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1

=== TEST 2: Multiple Date response headers, miss
--- http_config eval: $::HttpConfig
--- config
    location /multiple_date_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler({
                upstream_port = 12345
            }):run()
        }
    }
--- request
GET /multiple_date_headers_prx
--- tcp_listen: 12345
--- tcp_reply
HTTP/1.1 200 OK
Date: Mon, 24 Sep 2018 00:47:20 GMT
Server: Apache/2
Date: Mon, 24 Sep 2018 01:47:20 GMT
Cache-Control: public, max-age=300

TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- response_headers_unlike
Date: Mon, 24 Sep 2018 00:47:20 GMT
Date: Mon, 24 Sep 2018 01:47:20 GMT
--- response_body
TEST 2

=== TEST 2b: Multiple Date response headers, hit
--- http_config eval: $::HttpConfig
--- config
    location /multiple_date_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
--- request
GET /multiple_date_headers_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers_unlike
Date: Mon, 24 Sep 2018 00:47:20 GMT
Date: Mon, 24 Sep 2018 01:47:20 GMT
--- response_body
TEST 2
