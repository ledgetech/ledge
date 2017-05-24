use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-http/lib/?.lua;;";
}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: can_serve_stale
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local can_serve_stale = require("ledge.stale").can_serve_stale
        local res = {
            header = {}
        }

        assert(tostring(can_serve_stale(res)) == ngx.req.get_uri_args().stale,
            "can_serve_stale should be " .. ngx.req.get_uri_args().stale)

    }
}
--- more_headers eval
[
    "",
]
--- request eval
[
    "GET /t?stale=false",
]
--- no_error_log
[error]
