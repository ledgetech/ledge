use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: split_esi_token
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local esi = assert(require("ledge.esi"),
            "module should load without errors")

        local capability, version = esi.split_esi_token("ESI/1.0")
        assert(capability == "ESI" and version == 1.0,
            "capability and version should be returned")

        local ok, cap, ver = pcall(esi.split_esi_token)
        assert(ok and not cap and not ver,
            "split_esi_token without a token should safely return nil")
    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 2: esi_capabilities
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        assert(require("ledge.esi").esi_capabilities() == "ESI/1.0",
            "capabilities should be ESI/1.0")
    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 3: choose_esi_processor
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        -- handler stub
        local handler = {
            response = {
                header = {
                    ["Surrogate-Control"] = [[content=ESI/1.0]],
                }
            }
        }

        local processor = require("ledge.esi").choose_esi_processor(handler)

        assert(next(processor), "processor should be a table")

        assert(type(processor.get_scan_filter) == "function",
            "get_scan_filter should be a function")

        assert(type(processor.get_process_filter) == "function",
            "get_process_filter should be a function")

        -- unknown processor
        handler.response.header["Surrogate-Control"] = [[content=FOO/2.0]]

        assert(not require("ledge.esi").choose_esi_processor(handler),
            "processor should be nil")
    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 4: is_allowed_content_type
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local res = {
            header = {
                ["Content-Type"] = "text/html",
            }
        }

        local allowed_types = {
            "text/html"
        }

        local is_allowed_content_type =
            require("ledge.esi").is_allowed_content_type

        assert(is_allowed_content_type(res, allowed_types),
            "text/html is allowed")

        res.header["Content-Type"] = "text/ht"
        assert(not is_allowed_content_type(res, allowed_types),
            "text/ht is not allowed")

        res.header["Content-Type"] = "text/html_foo"
        assert(not is_allowed_content_type(res, allowed_types),
            "text/html_foo is not allowed")

        res.header["Content-Type"] = "text/html; charset=utf-8"
        assert(is_allowed_content_type(res, allowed_types),
            "text/html; charset=utf-8 is allowed")

        res.header["Content-Type"] = "text/json"
        assert(not is_allowed_content_type(res, allowed_types),
            "text/json is not allowed")


        table.insert(allowed_types, "text/json")
        assert(is_allowed_content_type(res, allowed_types),
            "text/json is allowed")

    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 5: can_delegate_to_surrogate
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local can_delegate_to_surrogate =
            require("ledge.esi").can_delegate_to_surrogate

        assert(not can_delegate_to_surrogate(true, "ESI/1.0"),
            "cannot delegate without capability")

        ngx.req.set_header("Surrogate-Capability", "localhost=ESI/1.0")

        assert(can_delegate_to_surrogate(true, "ESI/1.0"),
            "can delegate with capability")

        assert(not can_delegate_to_surrogate(true, "FOO/1.2"),
            "cannnot delegate to non-supported capability")

        assert(can_delegate_to_surrogate({ "127.0.0.1" }, "ESI/1.0" ),
            "can delegate to loopback with capability")

        assert(not can_delegate_to_surrogate({ "127.0.0.2" }, "ESI/1.0" ),
            "cant delegate to non-loopback with capability")

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 6: filter_esi_args
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        local filter_esi_args = require("ledge.esi").filter_esi_args

        local args = ngx.req.get_uri_args()
        assert(args.a == "1" and args.esi_foo == "bar bar" and args.b == "2",
            "request args should be intact")

        filter_esi_args(handler)

        local args = ngx.req.get_uri_args()
        assert(args.a == "1" and not args.esi_foo and args.b == "2",
            "esi args should be removed")

        assert(ngx.ctx.__ledge_esi_args.foo == "bar bar",
            "esi args should have foo: bar bar")

        assert(tostring(ngx.ctx.__ledge_esi_args) == "esi_foo=bar%20bar",
            "esi_args as a string should be foo=bar%20bar")

    }
}
--- request
GET /t?a=1&esi_foo=bar+bar&b=2
--- no_error_log
[error]
