use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

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
