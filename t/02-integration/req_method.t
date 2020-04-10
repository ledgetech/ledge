use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: GET
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
        ngx.say(ngx.req.get_method())
    }
}
--- request
GET /req_method_1_prx
--- response_body
GET
--- no_error_log
[error]


=== TEST 2: HEAD gets GET request
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1
--- no_error_log
[error]


=== TEST 3: HEAD revalidate
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
HEAD /req_method_1_prx
--- response_headers
Etag: req_method_1
--- no_error_log
[error]


=== TEST 4: GET still has body
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1
--- response_body
GET
--- no_error_log
[error]


=== TEST 5: POST does not get cached copy
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_posted"
        ngx.say(ngx.req.get_method())
    }
}
--- request
POST /req_method_1_prx
--- response_headers
Etag: req_method_posted
--- response_body
POST
--- no_error_log
[error]


=== TEST 6: GET uses cached POST response.
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_posted
--- response_body
POST
--- no_error_log
[error]


=== TEST 7: 501 on unrecognised method
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
FOOBAR /req_method_1
--- error_code: 501
--- no_error_log
[error]
