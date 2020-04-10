use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

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
