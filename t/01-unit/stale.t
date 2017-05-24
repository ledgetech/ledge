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

        local args =  ngx.req.get_uri_args()
        local res = {
            header = {
                ["Cache-Control"] = args.rescc,
            },
            remaining_ttl = tonumber(args.ttl),
        }

        assert(tostring(can_serve_stale(res)) == ngx.req.get_uri_args().stale,
            "can_serve_stale should be " .. ngx.req.get_uri_args().stale)

    }
}
--- more_headers eval
[
    "",
    "Cache-Control: max-stale=60",
    "Cache-Control: max-stale=60",
    "Cache-Control: max-stale=60",
    "Cache-Control: max-stale=9",
]
--- request eval
[
    "GET /t?rescc=&ttl=0&stale=false",
    "GET /t?rescc=&ttl=0&stale=true",
    "GET /t?rescc=must-revalidate&ttl=0&stale=false",
    "GET /t?rescc=proxy-revalidate&ttl=0&stale=false",
    "GET /t?rescc=&ttl=-10&stale=false",
]
--- no_error_log
[error]
