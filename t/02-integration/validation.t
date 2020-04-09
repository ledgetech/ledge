use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test1"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 100)
        ngx.say("TEST 1")
    }
}
--- request
GET /validation_prx
--- response_body
TEST 1
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 2: Unspecified end-to-end revalidation
    max-age=0 + no validator, upstream 200
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test2"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 90)
        ngx.say("TEST 2")
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 2b: Unspecified end-to-end revalidation
    max-age=0 + no validator, upstream 304
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- response_body
TEST 2
--- error_code: 200
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 3: Revalidate against cache using IMS in the future.
    Check we still have headers with our 304, and no body.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ngx.req.set_header(
            "If-Modified-Since",
            ngx.http_time(ngx.time() + 100)
        )
        require("ledge").create_handler():run()
    }
}
--- request
GET /validation_prx
--- error_code: 304
--- response_headers
Cache-Control: max-age=3600
Etag: test2
--- response_body
--- no_error_log
[error]


=== TEST 3b: Revalidate against cache using IMS in the past.
    Return 200 fresh cache.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ngx.req.set_header(
            "If-Modified-Since",
            ngx.http_time(ngx.time() - 100)
        )
        require("ledge").create_handler():run()
    }
}
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]


=== TEST 4: Revalidate against cache using Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- more_headers
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304
--- response_body
--- no_error_log
[error]


=== TEST 4b: Revalidate against cache using LM and Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ngx.req.set_header(
            "If-Modified-Since",
            ngx.http_time(ngx.time() + 100)
        )
        require("ledge").create_handler():run()
    }
}
--- more_headers
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304
--- response_body
--- no_error_log
[error]


=== TEST 5: Specific end-to-end revalidation using IMS, upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ngx.req.set_header(
            "If-Modified-Since",
            ngx.http_time(ngx.time() - 150)
        )
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 6: Specific end-to-end revalidation
    Using INM (matching), upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    }
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 304
--- no_error_log
[error]


=== TEST 6b: Specific end-to-end revalidation
    Using INM (not matching), upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    }
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test6b
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 2
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 7: Specific end-to-end revalidation using IMS, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ngx.req.set_header(
            "If-Modified-Since",
            ngx.http_time(ngx.time() - 150)
        )
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test7"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 70)
        ngx.say("TEST 7")
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 7
--- no_error_log
[error]


=== TEST 8: Specific end-to-end revalidation using INM, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test8"
        ngx.say("TEST 8")
    }
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 8
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]


=== TEST 8b: Unspecified end-to-end revalidation
    Using INM, upstream 200, validators now match (so 304 to client).
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test8b"
        ngx.say("TEST 8b")
    }
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test8b
--- request
GET /validation_prx
--- error_code: 304
--- response_body
--- no_error_log
[error]


=== TEST 8c: Check revalidation re-saved.
--- http_config eval: $::HttpConfig
--- config
location /validation_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /validation_prx
--- error_code: 200
--- response_body
TEST 8b
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]


=== TEST 9: Validators on a cache miss (should never 304).
--- http_config eval: $::HttpConfig
--- config
location /validation_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation_9 {
    content_by_lua_block {
        if ngx.req.get_headers()["Cache-Control"] == "max-age=0" and
            ngx.req.get_headers()["If-None-Match"] == "test9" then
            ngx.exit(ngx.HTTP_NOT_MODIFIED)
        else
            ngx.say("TEST 9")
        end
    }
}
--- more_headers
If-None-Match: test9
--- request
GET /validation_9_prx
--- error_code: 200
--- response_body
TEST 9
--- no_error_log
[error]


=== TEST 10: Re-Validation on an a cache miss using INM. Upstream 200, but valid once cached (so 304 to client).
--- http_config eval: $::HttpConfig
--- config
location /validation10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation10 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test10"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 60)
        ngx.say("TEST 10")
    }
}
--- more_headers
If-None-Match: test10
--- request
GET /validation10_prx
--- error_code: 304
--- response_body
--- no_error_log
[error]


=== TEST 11: Test badly formatted IMS is ignored.
--- http_config eval: $::HttpConfig
--- config
location /validation10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- more_headers
If-Modified-Since: 234qr12411224
--- request
GET /validation10_prx
--- error_code: 200
--- response_body
TEST 10
--- response_headers_like
X-Cache: HIT from .*
--- no_error_log
[error]


=== TEST 12: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /validation_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation_12 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "public, max-age=600"
        ngx.say("Test 12")
    }
}
--- request
GET /validation_12_prx
--- error_code: 200
--- response_body
Test 12
--- no_error_log
[error]


=== TEST 12a: IMS in req and missing LM does not 304
--- http_config eval: $::HttpConfig
--- config
location /validation_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation_12 {
    content_by_lua_block {
        ngx.say("Test 12")
    }
}
--- more_headers
If-Modified-Since: Tue, 29 Nov 2016 23:16:59 GMT
--- request
GET /validation_12_prx
--- error_code: 200
--- response_body
Test 12
--- no_error_log
[error]


=== TEST 12b: INM in req and missing etag does not 304
--- http_config eval: $::HttpConfig
--- config
location /validation_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /validation_12 {
    content_by_lua_block {
        ngx.say("Test 12")
    }
}
--- more_headers
If-None-Match: 1234
--- request
GET /validation_12_prx
--- error_code: 200
--- response_body
Test 12
--- no_error_log
[error]
