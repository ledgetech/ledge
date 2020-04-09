use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_lua_config => qq{
    package.loaded["state"] = {
        miss_count = 0,
    }
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Honour max-stale request header for an expired item
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0"
        end)
        handler:run()
    }
}
location /stale_1 {
    content_by_lua_block {
        local state = require("state")
        state.miss_count = state.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.print("TEST 1: ", state.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request eval
["GET /stale_1_prx", "GET /stale_1_prx"]
--- response_body eval
["TEST 1: 1", "TEST 1: 1"]
--- response_headers_like eval
["", 'Warning: 110 (?:[^\s]*) "Response is stale"']
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 1b: Confirm nothing was revalidated in the background
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_1_prx
--- response_body: TEST 1: 1
--- response_headers_like
Warning: 110 (?:[^\s]*) "Response is stale"
--- error_code eval
404
--- no_error_log
[error]


=== TEST 5: proxy-revalidate must revalidate (not serve stale)
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0, proxy-revalidate"
        end)
        handler:run()
    }
}
location /stale_5 {
    content_by_lua_block {
        local state = require("state")
        state.miss_count = state.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600, proxy-revalidate"
        ngx.print("TEST 5: ", state.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120
--- request eval
["GET /stale_5_prx", "GET /stale_5_prx"]
--- response_body eval
["TEST 5: 1", "TEST 5: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 6: must-revalidate must revalidate (not serve stale)
--- http_config eval: $::HttpConfig
--- config
location /stale_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0, must-revalidate"
        end)
        handler:run()
    }
}
location /stale_6 {
    content_by_lua_block {
        local state = require("state")
        state.miss_count = state.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600, must-revalidate"
        ngx.print("TEST 6: ", state.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120
--- request eval
["GET /stale_6_prx", "GET /stale_6_prx"]
--- response_body eval
["TEST 6: 1", "TEST 6: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 7: Can serve stale but must revalidate because of Age
--- http_config eval: $::HttpConfig
--- config
location /stale_7_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0"
        end)
        handler:run()
    }
}
location /stale_7 {
    content_by_lua_block {
        local state = require("state")
        state.miss_count = state.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 7: ", state.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120, max-age=1
--- request eval
["GET /stale_7_prx", "GET /stale_7_prx"]
--- response_body eval
["TEST 7: 1", "TEST 7: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]
--- wait: 2
