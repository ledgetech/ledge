use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Header case insensitivity
--- http_config eval: $::HttpConfig
--- config
location /response_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("after_upstream_request", function(res)
            if res.header["X-tesT"] == "1" then
                res.header["x-TESt"] = "2"
            end

            if res.header["X-TEST"] == "2" then
                res.header["x-test"] = "3"
            end
        end)
        handler:run()
    }
}
location /response_1 {
    content_by_lua_block {
        ngx.header["X-Test"] = "1"
        ngx.say("OK")
    }
}
--- request
GET /response_1_prx
--- response_headers
X-Test: 3
--- no_error_log
[error]


=== TEST 2: TTL from s-maxage (overrides max-age / Expires)
--- http_config eval: $::HttpConfig
--- config
location /response_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            res.header["X-TTL"] = res:ttl()
        end)
        handler:run()
    }
}
location /response_2 {
    content_by_lua_block {
        ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
        ngx.header["Cache-Control"] = "max-age=600, s-maxage=1200"
        ngx.say("OK")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /response_2_prx
--- response_headers
X-TTL: 1200
--- no_error_log
[error]


=== TEST 3: TTL from max-age (overrides Expires)
--- http_config eval: $::HttpConfig
--- config
location /response_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            res.header["X-TTL"] = res:ttl()
        end)
        handler:run()
    }
}
location /response_3 {
    content_by_lua_block {
        ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
        ngx.header["Cache-Control"] = "max-age=600"
        ngx.say("OK")
        }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /response_3_prx
--- response_headers
X-TTL: 600
--- no_error_log
[error]


=== TEST 4: TTL from Expires
--- http_config eval: $::HttpConfig
--- config
location /response_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            res.header["X-TTL"] = res:ttl()
        end)
        handler:run()
        }
}
location /response_4 {
    content_by_lua_block {
        ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
        ngx.say("OK")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /response_4_prx
--- response_headers
X-TTL: 300
--- no_error_log
[error]


=== TEST 4b: TTL from Expires, when there are multiple Expires headers
--- http_config eval: $::HttpConfig
--- config
location /response_4b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            res.header["X-TTL"] = res:ttl()
        end)
        handler:run()
    }
}
location /response_4b {
    set $ttl_1 0;
    set $ttl_2 0;
    access_by_lua_block {
        ngx.var.ttl_1 = ngx.http_time(ngx.time() + 300)
        ngx.var.ttl_2 = ngx.http_time(ngx.time() + 100)
    }
    add_header Expires $ttl_1;
    add_header Expires $ttl_2;
    echo "OK";
}
--- more_headers
Cache-Control: no-cache
--- request
GET /response_4b_prx
--- response_headers
X-TTL: 100
--- no_error_log
[error]
