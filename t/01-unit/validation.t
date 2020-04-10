use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: must_revalidate
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local must_revalidate = require("ledge.validation").must_revalidate

        local res = {
            header = {
                ["Cache-Control"] = ngx.req.get_headers().x_res_cache_control,
                ["Age"] = ngx.req.get_headers().x_res_age,
            },
        }

        local result = ngx.req.get_uri_args().result
        assert(tostring(must_revalidate(res)) == result,
            "must_revalidate should be " .. result)

    }
}
--- more_headers eval
[
    "",
    "Cache-Control: max-age=0",
    "Cache-Control: max-age=1
X-Res-Age: 1",
    "Cache-Control: max-age=1
X-Res-Age: 2",
    "X-Res-Cache-Control: must-revalidate",
    "X-Res-Cache-Control: proxy-revalidate",
]
--- request eval
[
    "GET /t?&result=false",
    "GET /t?&result=true",
    "GET /t?&result=false",
    "GET /t?&result=true",
    "GET /t?&result=true",
    "GET /t?&result=true",
]
--- no_error_log
[error]


=== TEST 2: can_revalidate_locally
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local can_revalidate_locally =
            require("ledge.validation").can_revalidate_locally

        local result = ngx.req.get_uri_args().result
        assert(tostring(can_revalidate_locally()) == result,
            "can_revalidate_locally should be " .. result)

    }
}
--- more_headers eval
[
    "",
    "If-None-Match:" ,
    "If-None-Match: foo",
    "If-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT",
    "If-Modified-Since:",
    "If-Modified-Since: foo",
]
--- request eval
[
    "GET /t?&result=false",
    "GET /t?&result=false",
    "GET /t?&result=true",
    "GET /t?&result=true",
    "GET /t?&result=false",
    "GET /t?&result=false",
]
--- no_error_log
[error]


=== TEST 3: is_valid_locally
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local is_valid_locally = require("ledge.validation").is_valid_locally

        local res = {
            header = {
                ["Last-Modified"] = ngx.req.get_headers().x_res_last_modified,
                ["Etag"] = ngx.req.get_headers().x_res_etag,
            },
        }

        local result = ngx.req.get_uri_args().result
        assert(tostring(is_valid_locally(res)) == result,
            "is_valid_locally should be " .. result)

    }
}
--- more_headers eval
[
    "",
    "If-Modified-Since: Sun, 05 Nov 1994 08:49:37 GMT
X-Res-Last-Modified: Sun, 06 Nov 1994 08:48:37 GMT",
    "If-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT
X-Res-Last-Modified: Sun, 06 Nov 1994 08:48:37 GMT",
    "If-Modified-Since: Sun, 06 Nov 1994 08:49:38 GMT
X-Res-Last-Modified: Sun, 06 Nov 1994 08:48:37 GMT",
    "If-Modified-Since: Sun, 06 Nov 1994 08:49:36 GMT
X-Res-Last-Modified: Sun, 06 Nov 1994 08:49:37 GMT",
    "If-None-Match: foo
X-Res-Etag: foo",
    "If-None-Match: foo
X-Res-Etag: bar",
    "If-None-Match: foo",
    "X-Res-Etag: bar",
]
--- request eval
[
    "GET /t?&result=false",
    "GET /t?&result=false",
    "GET /t?&result=true",
    "GET /t?&result=true",
    "GET /t?&result=false",
    "GET /t?&result=true",
    "GET /t?&result=false",
    "GET /t?&result=false",
    "GET /t?&result=false",
]
--- no_error_log
[error]
