use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    require("ledge").set_handler_defaults({
        esi_enabled = true,
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
}

};

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Prime some cache
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_1_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location "/mem_pressure_1" {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Surrogate-Control"] = [[content="ESI/1.0"]]
        ngx.print("<esi:vars></esi:vars>Key: ", ngx.req.get_uri_args()["key"])
    }
}
--- request eval
["GET /mem_pressure_1_prx?key=main",
"GET /mem_pressure_1_prx?key=headers",
"GET /mem_pressure_1_prx?key=entities"]
--- response_body eval
["Key: main",
"Key: headers",
"Key: entities"]
--- no_error_log
[error]


=== TEST 1b: Break each key, in a different way for each, then try to serve
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_1_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        local key_chain = handler:cache_key_chain()

        local evict = ngx.req.get_uri_args()["key"]
        local key = key_chain[evict]
        ngx.log(ngx.DEBUG, "will evict: ", key)
        local res, err = redis:del(key)
        if not res then
            ngx.log(ngx.ERR, "could not evict: ", err)
        end
        redis:set(evict, "true")
        ngx.log(ngx.DEBUG, tostring(res))

        redis:close()

        handler:run()
    }
}

location "/mem_pressure_1" {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=0"
        ngx.print("MISSED: ", ngx.req.get_uri_args()["key"])
    }
}
--- request eval
["GET /mem_pressure_1_prx?key=main",
"GET /mem_pressure_1_prx?key=headers",
"GET /mem_pressure_1_prx?key=entities"]
--- response_body eval
["MISSED: main",
"MISSED: headers",
"MISSED: entities"]
--- no_error_log
[error]


=== TEST 2: Prime and break ::main before transaction completes
(leaves it partial)
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_2_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            local main = handler:cache_key_chain().main
            handler.redis:del(main)
        end)
        handler:run()
    }
}
location "/mem_pressure_2" {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("ORIGIN")
    }
}
--- request
GET /mem_pressure_2_prx
--- response_body: ORIGIN
--- no_error_log
[error]


=== TEST 2b: Confirm broken ::main doesnt get served
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_2_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location "/mem_pressure_2" {
    default_type text/html;
    content_by_lua_block {
        ngx.print("ORIGIN")
    }
}
--- request
GET /mem_pressure_2_prx
--- response_body: ORIGIN
--- no_error_log
[error]
