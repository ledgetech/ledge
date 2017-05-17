use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;;";
}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Purge mode
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local req_purge_mode = assert(require("ledge.request").purge_mode,
            "request module should load without errors")

        local mode = ngx.req.get_uri_args()["p"]
        assert(req_purge_mode() == mode,
            "req_purge_mode should equal " .. mode)


    }
}
--- more_headers eval
["X-Purge: delete",
"X-Purge: revalidate",
"X-Purge: invalidate",
""]
--- request eval
["GET /t?p=delete",
"GET /t?p=revalidate",
"GET /t?p=invalidate",
"GET /t?p=invalidate"]
--- no_error_log
[error]


=== TEST 2: Relative uri
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local req_relative_uri = require("ledge.request").relative_uri
        assert(req_relative_uri() == "/t")
    }
}
--- request eval
["GET /t",
]
--- no_error_log
[error]
