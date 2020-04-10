use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_lua_config => qq{
    require("ledge").set_handler_defaults({
        storage_driver_config = {
            max_size = 8,
        }
    })
});

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Response larger than cache_max_memory.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("RESPONSE IS TOO LARGE TEST 1")
    }
}
--- request
GET /max_memory_prx
--- response_body
RESPONSE IS TOO LARGE TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- error_log
storage failed to write: body is larger than 8 bytes


=== TEST 2: Test we did not store in previous test.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
    }
}
--- request
GET /max_memory_prx
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log


=== TEST 3: Non-chunked response larger than cache_max_memory.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory_3 {
    chunked_transfer_encoding off;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        local body = "RESPONSE IS TOO LARGE TEST 3\n"
        ngx.header["Content-Length"] = string.len(body)
        ngx.print(body)
    }
}
--- request
GET /max_memory_3_prx
--- response_body
RESPONSE IS TOO LARGE TEST 3
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log


=== TEST 4: Test we did not store in previous test.
--- http_config eval: $::HttpConfig
--- config
location /max_memory_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory_3 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4")
    }
}
--- request
GET /max_memory_3_prx
--- response_body
TEST 4
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log


=== TEST 5a: Prime cache with ok size
--- http_config eval: $::HttpConfig
--- config
location /max_memory_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory_5 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- request
GET /max_memory_5_prx
--- response_body
OK
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 5b: Try to replace with a large response
--- http_config eval: $::HttpConfig
--- config
location /max_memory_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /max_memory_5 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("RESPONSE IS TOO LARGE")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /max_memory_5_prx
--- response_body
RESPONSE IS TOO LARGE
--- response_headers_like
X-Cache: MISS from .*
--- error_log
larger than 8 bytes


=== TEST 5c: Confirm original cache is still ok
--- http_config eval: $::HttpConfig
--- config
location /max_memory_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /max_memory_5_prx
--- response_body
OK
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]
