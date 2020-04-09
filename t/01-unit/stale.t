use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

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


=== TEST 2: verify_stale_conditions
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local verify_stale_conditions =
            require("ledge.stale").verify_stale_conditions

        local args =  ngx.req.get_uri_args()

        local res = {
            header = {
                ["Cache-Control"] = ngx.req.get_headers().x_res_cache_control,
                ["Age"] = ngx.req.get_headers().x_res_age,
            },
            remaining_ttl = tonumber(args.ttl),
        }

        local token = ngx.req.get_uri_args().token
        local stale = ngx.req.get_uri_args().stale
        assert(tostring(verify_stale_conditions(res, token)) == stale,
            "verify_stale_conditions should be " .. stale)

        if token == "stale-while-revalidate" then

            local can_serve_stale_while_revalidate =
                require("ledge.stale").can_serve_stale_while_revalidate

            assert(tostring(can_serve_stale_while_revalidate(res)) == stale,
                "can_serve_stale_while_revalidate should be " .. stale)
        elseif token == "stale-if-error" then

            local can_serve_stale_if_error = 
                require("ledge.stale").can_serve_stale_if_error

            assert(tostring(can_serve_stale_if_error(res)) == stale,
                "can_serve_stale_if_error should be " .. stale)
        end

    }
}
--- more_headers eval
[
    "",
    "Cache-Control: stale-while-revalidate=60",
    "X-Res-Cache-Control: stale-while-revalidate=60",
    "Cache-Control: min-fresh=10
X-Res-Cache-Control: stale-while-revalidate=60",
    "Cache-Control: max-age=10, stale-while-revalidate=60
X-Res-Age: 5",
    "Cache-Control: max-age=4, stale-while-revalidate=60
X-Res-Age: 5",
    "Cache-Control: max-stale=10, stale-while-revalidate=60",
    "Cache-Control: max-stale=60, stale-while-revalidate=60",
]
--- request eval
[
    "GET /t?token=stale-while-revalidate&stale=false",
    "GET /t?token=stale-while-revalidate&stale=true",
    "GET /t?token=stale-while-revalidate&stale=true",
    "GET /t?token=stale-while-revalidate&stale=false",
    "GET /t?token=stale-while-revalidate&stale=true",
    "GET /t?token=stale-while-revalidate&stale=false",
    "GET /t?token=stale-while-revalidate&stale=false",
    "GET /t?token=stale-while-revalidate&stale=true",
]
--- no_error_log
[error]
