use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();
$ENV{TEST_NGINX_SOCKET_DIR} ||= $ENV{TEST_NGINX_HTML_DIR};

our $HttpConfig = LedgeEnv::http_config();

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

=== TEST 2: Short read timeout does not result in responses getting mixed up
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

location /other_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({}):run()
    }
}

location /upstream {
    content_by_lua_block {
        ngx.sleep(1)
        ngx.say("upstream")
    }
}

location /other {
    content_by_lua_block {
        ngx.say("other")
    }
}
--- request eval
["GET /upstream_prx", "GET /other_prx", "GET /other_prx", "GET /other_prx"]
--- error_code eval
[524, 200, 200, 200]
--- response_body eval
["", "other\n", "other\n", "other\n"]


=== TEST 3: No upstream results in a 503.
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


=== TEST 4: No port results in 503
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


=== TEST 5: No port with unix socket works
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
