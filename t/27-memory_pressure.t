use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 24;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
		ledge_mod = require 'ledge.ledge'
        ledge_mod.DEBUG = true
        ledge = ledge_mod:new()
        ledge:config_set("redis_connection", {
            socket = "$ENV{TEST_LEDGE_REDIS_SOCKET}",
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        })
        ledge:config_set("storage_connection", {
            socket = "$ENV{TEST_LEDGE_REDIS_SOCKET}",
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        })
        ledge:config_set("redis_qless_database", $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set("esi_enabled", true)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime some cache
--- http_config eval: $::HttpConfig
--- config
	location "/mem_pressure_1_prx" {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
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
            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_connection").db)
            ledge:ctx().redis = redis

            local key_chain = ledge:cache_key_chain()

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
            ledge:ctx().redis = nil

            ledge:run()
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


=== TEST 2: Prime and break ::main before transaction completes (leaves it partial)
--- http_config eval: $::HttpConfig
--- config
    location "/mem_pressure_2_prx" {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:bind("response_ready", function(res)
                local redis = ledge:ctx().redis
                local main = ledge:cache_key_chain().main
                redis:del(main)
            end)
            ledge:run()
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
=== TEST 2b: Confirm broken ::main doesn't get served
--- http_config eval: $::HttpConfig
--- config
    location "/mem_pressure_2_prx" {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
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
