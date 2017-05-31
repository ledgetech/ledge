use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-http/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        jit.off()
        require("luacov.runner").init()
    end

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
[
    "X-Purge: delete",
    "X-Purge: revalidate",
    "X-Purge: invalidate",
    ""
]
--- request eval
[
    "GET /t?p=delete",
    "GET /t?p=revalidate",
    "GET /t?p=invalidate",
    "GET /t?p=invalidate"
]
--- no_error_log
[error]


=== TEST 2: relative_uri - spaces encoded
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


=== TEST 3: relative_uri - Percent encode encoded CRLF
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


=== TEST 4: full_uri
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local full_uri = require("ledge.request").full_uri
        assert(full_uri() == "http://localhost/t",
            "full_uri should be http://localhost/t")
    }

}
--- request
GET /t
--- no_error_log
[error]


=== TEST 5: visible_hostname
--- http_config eval: $::HttpConfig
--- config
location /t {
    set $visible_hostname $hostname;
    content_by_lua_block {
        local visible_hostname = require("ledge.request").visible_hostname
        local host = ngx.var.hostname .. ":" .. ngx.var.server_port
        assert(visible_hostname() == host,
            "visible_hostname should be " .. host)

        -- Test overriding the visible_hostname
        ngx.var.visible_hostname = "example.com"
        host = "example.com:" .. ngx.var.server_port
        assert(visible_hostname() == host,
            "visible_hostname should be " .. host)
    }

}
--- request
GET /t
--- no_error_log
[error]


=== TEST 6: accepts_cache
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local accepts_cache = require("ledge.request").accepts_cache
        assert(tostring(accepts_cache()) == ngx.req.get_uri_args().c,
            "accepts_cache should be " .. ngx.req.get_uri_args().c)
    }

}
--- more_headers eval
[
    "Cache-Control: no-cache",
    "Cache-Control: no-store",
    "Pragma: no-cache",
    "Cache-Control: no-cache, max-age=60",
    "Cache-Control: s-maxage=20, no-cache",
    "",
    "Cache-Control: max-age=60",
    "Cache-Control: max-age=0",
    "Pragma: cache",
    "Cache-Control: no-cachey",
]
--- request eval
[
    "GET /t?c=false",
    "GET /t?c=false",
    "GET /t?c=false",
    "GET /t?c=false",
    "GET /t?c=false",
    "GET /t?c=true",
    "GET /t?c=true",
    "GET /t?c=true",
    "GET /t?c=true",
    "GET /t?c=true"
]
--- no_error_log
[error]
