use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_nginx_config => qq{
    lua_shared_dict test 1m;
    lua_check_client_abort on;
    if_modified_since off;
}, extra_lua_config => qq{
    require("ledge").set_handler_defaults({
        esi_enabled = true,
        buffer_size = 5, -- Try to trip scanning up with small buffers
    })

    -- Make all content return valid Surrogate-Control headers
    function run(handler)
        if not handler then
            handler = require("ledge").create_handler()
        end
        handler:bind("after_upstream_request", function(res)
            res.header["Surrogate-Control"] = [[content="ESI/1.0"]]
        end)
        handler:run()
    end
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 42: By default includes to 3rd party domains are allowed
--- http_config eval: $::HttpConfig
--- config
location /esi_42_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        run()
    }
}
location /esi_42 {
    default_type text/html;
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local content = [[<esi:include src="https://jsonplaceholder.typicode.com/todos/1" />]]
        ngx.say(content)
    }
}
--- request
GET /esi_42_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
{
  "userId": 1,
  "id": 1,
  "title": "delectus aut autem",
  "completed": false
}
--- no_error_log
[error]


=== TEST 43: Disable third party includes
--- http_config eval: $::HttpConfig
--- config
location /esi_43_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            esi_disable_third_party_includes = true,
        })
        run(handler)
    }
}
location /esi_43 {
    default_type text/html;
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local content = [[<esi:include src="https://jsonplaceholder.typicode.com/todos/1" />]]
        ngx.print(content)
    }
}
--- request
GET /esi_43_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body:
--- no_error_log
[error]


=== TEST 44: White list third party includes
--- http_config eval: $::HttpConfig
--- config
location /esi_44_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            esi_disable_third_party_includes = true,
            esi_third_party_includes_domain_whitelist = {
                ["jsonplaceholder.typicode.com"] = true,
            },
        })
        run(handler)
    }
}
location /esi_44 {
    default_type text/html;
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local content = [[<esi:include src="https://jsonplaceholder.typicode.com/todos/1" />]]
        ngx.say(content)
    }
}
--- request
GET /esi_44_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
{
  "userId": 1,
  "id": 1,
  "title": "delectus aut autem",
  "completed": false
}
--- no_error_log
[error]


=== TEST 45: Cookies and Authorization propagate to fragment on same domain
--- http_config eval: $::HttpConfig
--- config
location /esi_45_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        run()
    }
}
location /fragment_1 {
    content_by_lua_block {
        ngx.say("method: ", ngx.req.get_method())
        local h = ngx.req.get_headers()

        local h_keys = {}
        for k,v in pairs(h) do
            table.insert(h_keys, k)
        end
        table.sort(h_keys)

        for _,k in ipairs(h_keys) do
            ngx.say(k, ": ", h[k])
        end
    }
}
location /esi_45 {
    default_type text/html;
    content_by_lua_block {
        ngx.print([[<esi:include src="/fragment_1" />]])
    }
}
--- request
POST /esi_45_prx
--- more_headers
Cache-Control: no-cache
Cookie: foo
Authorization: bar
Range: bytes=0-
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body_like
method: GET
authorization: bar
cache-control: no-cache
cookie: foo
host: localhost
user-agent: lua-resty-http/\d+\.\d+ \(Lua\) ngx_lua/\d+ ledge_esi/\d+\.\d+[\.\d]*
x-esi-parent-uri: http://localhost/esi_45_prx
x-esi-recursion-level: 1
--- no_error_log
[error]


=== TEST 45b: Cookies and Authorization don't propagate to fragment on different domain
--- http_config eval: $::HttpConfig
--- config
location /esi_45_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        run()
    }
}
location /esi_45 {
    default_type text/html;
    content_by_lua_block {
        ngx.print([[<esi:include src="https://mockbin.org/request" />]])
    }
}
--- request
POST /esi_45_prx
--- more_headers
Cache-Control: no-cache
Cookie: foo
Authorization: bar
Range: bytes=0-
Accept: text/plain
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body_like
(.*)"method": "GET",
(.*)"cache-control": "no-cache",
--- response_body_unlike
(.*)"authorization": "bar",
(.*)"cookie": "foo",
--- no_error_log
[error]


=== TEST 46: Cookie var blacklist
--- http_config eval: $::HttpConfig
--- config
location /esi_46_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            esi_vars_cookie_blacklist = {
                not_allowed  = true,
            },
        })
        run(handler)
    }
}
location /esi_46 {
    default_type text/html;
    content_by_lua_block {
        -- Blacklist should apply to expansion in vars
        ngx.say([[<esi:vars>$(HTTP_COOKIE)</esi:vars>]])

        -- And by key
        ngx.say([[<esi:vars>$(HTTP_COOKIE{allowed}):$(HTTP_COOKIE{not_allowed})</esi:vars>]])

        -- ...and also in URIs
        ngx.say([[<esi:include src="/fragment?&allowed=$(HTTP_COOKIE{allowed})&not_allowed=$(HTTP_COOKIE{not_allowed})" />]])
    }
}
location /fragment {
    content_by_lua_block {
        ngx.say("FRAGMENT:"..ngx.var.args)

        -- But ALL cookies are still propagated by default to subrequests
        local cookie = require("resty.cookie").new()
        ngx.print(cookie:get("allowed") .. ":" .. cookie:get("not_allowed"))
    }
}
--- request
GET /esi_46_prx
--- more_headers
Cookie: allowed=yes
Cookie: also_allowed=yes
Cookie: not_allowed=no
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
allowed=yes; also_allowed=yes
yes:
FRAGMENT:&allowed=yes&not_allowed=
yes:no
--- no_error_log
[error]
