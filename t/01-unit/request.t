use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-http/lib/?.lua;;";

init_by_lua_block {
    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
}

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


=== TEST 2: Relative uri - spaces encoded
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local http = require("resty.http").new()
        http:connect(
            "127.0.0.1", TEST_NGINX_PORT
        )

        local res, err = http:request({
            path = "/t with spaces",
        })

        http:close()
    }

}

location "/t with spaces" {
    content_by_lua_block {
        local req_relative_uri = require("ledge.request").relative_uri
        assert(req_relative_uri() == "/t%20with%20spaces",
            "uri should have spaces encoded")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 3: Relative uri - Percent encode encoded CRLF
http://resources.infosecinstitute.com/http-response-splitting-attack
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local http = require("resty.http").new()
        http:connect(
            "127.0.0.1", TEST_NGINX_PORT
        )

        local res, err = http:request({
            path = "/t_crlf_encoded_%250d%250A",
        })

        http:close()
    }

}

location /t_crlf_encoded_ {
    content_by_lua_block {
        local req_relative_uri = require("ledge.request").relative_uri
        assert(req_relative_uri() == "/t_crlf_encoded_%250D%250A",
            "encoded crlf in uri should be escaped")
    }
}
--- request
GET /t
--- no_error_log
[error]
