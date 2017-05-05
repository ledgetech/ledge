use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 2;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        jit.off()
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load module without errors.
--- http_config eval: $::HttpConfig
--- config
location /ledge_1 {
    content_by_lua_block {
        assert(require("ledge"), "module should load without errors")
    }
}
--- request
GET /ledge_1
--- no_error_log
[error]


=== TEST 2: Module cannot be externally modified
--- http_config eval: $::HttpConfig
--- config
location /ledge_2 {
    content_by_lua_block {
        local ledge = require("ledge")
        ledge.foo = "bar"
    }
}
--- request
GET /ledge_2
--- error_log
attempt to create new field foo
--- error_code: 500


=== TEST 3: Non existent params cannot be set
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";
init_by_lua_block {
    require("ledge").configure({ foo = "bar" })
}
--- config
location /ledge_3 {
    echo "OK";
}
--- request
GET /ledge_3
--- error_log
field foo does not exist
--- must_die


=== TEST 4: Params cannot be set outside of init
--- http_config eval: $::HttpConfig
--- config
location /ledge_4 {
    content_by_lua_block {
        require("ledge").configure({ qless_db = 4 })
    }
}
--- request
GET /ledge_4
--- error_code: 500
--- error_log
attempt to call configure outside the 'init' phase


=== TEST 5: Create redis connection
--- http_config eval: $::HttpConfig
--- config
location /ledge_5 {
    content_by_lua_block {
        local redis = assert(require("ledge").create_redis_connection(),
            "create_redis_connection() should return positively")

        assert(redis:set("ledge_5:cat", "dog"),
            "redis:set() should return positively")

        ngx.say(redis:get("ledge_5:cat"))

        assert(require("ledge").close_redis_connection(redis),
            "close_redis_connection() should return positively")
    }
}
--- request
GET /ledge_5
--- response_body
dog
--- no_error_log
[error]


=== TEST 6: Create bad redis connection
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    require("ledge").configure({
        redis_connector_params = {
            port = 0, -- bad port
        },
    })
}
--- config
location /ledge_6 {
    content_by_lua_block {
        assert(not require("ledge").create_redis_connection(),
            "create_redis_connection() should return negatively")
    }
}
--- request
GET /ledge_6
--- error_log
Connection refused


=== TEST 7: Create storage connection
--- http_config eval: $::HttpConfig
--- config
location /ledge_7 {
    content_by_lua_block {
        local storage = assert(require("ledge").create_storage_connection(),
            "create_storage_connection should return positively")

        ngx.say(storage:exists("ledge_7:123456"))

        assert(require("ledge").close_storage_connection(storage),
            "close_storage_connection() should return positively")
    }
}
--- request
GET /ledge_7
--- response_body
false
--- no_error_log
[error]


=== TEST 8: Create bad storage connection
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    require("ledge").set_handler_defaults({
        storage_driver_config = {
            redis_connector = {
                port = 0,
            },
        }
    })
}
--- config
location /ledge_8 {
    content_by_lua_block {
        assert(not require("ledge").create_storage_connection(),
            "create_storage_connection() should return negatively")
    }
}
--- request
GET /ledge_8
--- error_log
Connection refused
