use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;;";
}; # HttpConfig

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
            "can_serve_stale should be " .. result)

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
