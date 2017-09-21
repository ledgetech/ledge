use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;
$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();
$ENV{TEST_NGINX_SOCKET_DIR} ||= $ENV{TEST_NGINX_HTML_DIR};

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
=== TEST 1: Short read timeout results in error 524.
--- http_config eval: $::HttpConfig
--- config
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_send_timeout = 5000,
            upstream_connect_timeout = 5000,
            upstream_read_timeout = 100,
        }):run()
    }
}
location /upstream {
    content_by_lua_block {
        ngx.sleep(1)
        ngx.say("OK")
    }
}
--- request
GET /upstream_prx
--- error_code: 524
--- response_body
--- error_log
timeout


=== TEST 2: No upstream results in a 503.
--- http_config eval: $::HttpConfig
--- config
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_host = "",
        }):run()
    }
}
--- request
GET /upstream_prx
--- error_code: 503
--- response_body
--- error_log
upstream connection failed:


=== TEST 3: No port results in 503
--- http_config eval: $::HttpConfig
--- config
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_host = "127.0.0.1",
            upstream_port = "",
        }):run()
    }
}
--- request
GET /upstream_prx
--- error_code: 503
--- response_body
--- error_log
upstream connection failed:


=== TEST 4: No port with unix socket works
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_SOCKET_DIR/nginx.sock;
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_host = "unix:$TEST_NGINX_SOCKET_DIR/nginx.sock",
            upstream_port = "",
        }):run()
    }
}
location /upstream {
    echo "OK";
}
--- request
GET /upstream_prx
--- error_code: 200
--- response_body
OK
--- no_error_log
[error]
