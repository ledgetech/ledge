use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_lua_config => qq{
    require("ledge").set_handler_defaults({
        esi_enabled = true,
    })
}, run_worker => 1);

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
        handler.redis = redis
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

=== TEST 3: Prime and break active entity during read
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_3_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        if not ngx.req.get_uri_args()["prime"] then
            handler:bind("before_serve", function(res)
                ngx.log(ngx.DEBUG, "Deleting: ", res.entity_id)
                handler.storage:delete(res.entity_id)
            end)
        else
            -- Dummy log for prime request
            ngx.log(ngx.DEBUG, "entity removed during read")
        end
        ngx.req.set_uri_args({})
        handler:run()
    }
}
location "/mem_pressure_3" {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("ORIGIN")
    }
}
--- request eval
["GET /mem_pressure_3_prx?prime=true", "GET /mem_pressure_3_prx"]
--- response_body eval
["ORIGIN", ""]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: HIT from .*"]
--- no_error_log
[error]
--- error_log
entity removed during read

=== TEST 4: Prime some cache - stale headers
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_4_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location "/mem_pressure_4" {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600, stale-if-error=2592000, stale-while-revalidate=129600"
        ngx.header["Surrogate-Control"] = [[content="ESI/1.0"]]
        ngx.print("<esi:vars></esi:vars>Key: ", ngx.req.get_uri_args()["key"])
    }
}
--- request eval
["GET /mem_pressure_4_prx?key=main",
"GET /mem_pressure_4_prx?key=headers",
"GET /mem_pressure_4_prx?key=entities"]
--- response_body eval
["Key: main",
"Key: headers",
"Key: entities"]
--- no_error_log
[error]


=== TEST 4b: Break each key, in a different way for each, then try to serve
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_4_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
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

location "/mem_pressure_4" {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=0"
        ngx.print("MISSED: ", ngx.req.get_uri_args()["key"])
    }
}
--- request eval
["GET /mem_pressure_4_prx?key=main",
"GET /mem_pressure_4_prx?key=headers",
"GET /mem_pressure_4_prx?key=entities"]
--- response_body eval
["MISSED: main",
"MISSED: headers",
"MISSED: entities"]
--- no_error_log
[error]

=== TEST 5: Prime and break active entity during read - ESI
--- http_config eval: $::HttpConfig
--- config
location "/mem_pressure_5_prx" {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        if not ngx.req.get_uri_args()["prime"] then
            handler:bind("before_serve", function(res)
                ngx.log(ngx.DEBUG, "Deleting: ", res.entity_id)
                handler.storage:delete(res.entity_id)
            end)
        else
            -- Dummy log for prime request
            require("ledge.state_machine").set_debug(true)
            ngx.log(ngx.DEBUG, "entity removed during read")
        end
        ngx.req.set_uri_args({})
        handler:run()
    }
}
location "/mem_pressure_5" {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Surrogate-Control"] = 'content="ESI/1.0"'
        ngx.print("ORIGIN")
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    }
}
--- request eval
["GET /mem_pressure_5_prx?prime=true", "GET /mem_pressure_5_prx"]
--- response_body eval
["ORIGIN", ""]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: HIT from .*"]
--- no_error_log
[error]
--- error_log
entity removed during read
