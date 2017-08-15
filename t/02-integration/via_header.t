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
=== TEST 1: Ledge version advertised by default
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /t {
    echo "ORIGIN";
}
--- request
GET /t_prx
--- response_headers_like
Via: \d+\.\d+ .+ \(ledge/\d+\.\d+[\.\d]*\)
--- no_error_log
[error]


=== TEST 2: Ledge version not advertised
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            advertise_ledge = false,
        }):run()
    }
}
location /t {
    echo "ORIGIN";
}
--- request
GET /t_prx
--- raw_response_headers_unlike: Via: \d+\.\d+ .+ \(ledge/\d+\.\d+[\.\d]*\)
--- no_error_log
[error]


=== TEST 3: Via header uses visible_hostname config
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            visible_hostname = "ledge.example.com"
        }):run()
    }
}
location /t {
    echo "ORIGIN";
}
--- request
GET /t_prx
--- response_headers_like
Via: \d+\.\d+ ledge.example.com:\d+ \(ledge/\d+\.\d+[\.\d]*\)
--- no_error_log
[error]


=== TEST 4: Via header from upstream
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /t {
    content_by_lua_block {
        ngx.header["Via"] = "1.1 foo"
    }
}
--- request
GET /t_prx
--- more_headers
Cache-Control: no-cache
--- response_headers_like
Via: \d+\.\d+ .+ \(ledge/\d+\.\d+[\.\d]*\), \d+\.\d+ foo
--- no_error_log
[error]


=== TEST 5: Erroneous multiple Via headers from upstream
--- http_config eval: $::HttpConfig
--- config
location /t_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_port = 1985,
        }):run()
    }
}
--- tcp_listen: 1985
--- tcp_reply
HTTP/1.1 200 OK
Content-Length: 2
Content-Type: text/plain
Via: 1.1 foo
Via: 1.1 foo.bar

OK

--- request
GET /t_prx
--- more_headers
Cache-Control: no-cache
--- response_body: OK
--- response_headers_like
Via: 1.1 .+ \(ledge/\d+\.\d+[\.\d]*\), 1.1 foo, 1.1 foo.bar
--- no_error_log
[error]
