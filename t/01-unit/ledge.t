use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE}
    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = qless_db,
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
        local ok, err = pcall(function()
            ledge.foo = "bar"
        end)
        assert(string.find(err,  "attempt to create new field foo"),
            "error 'field foo does not exist' should be thrown")
    }
}
--- request
GET /ledge_2
--- no_error_log
[error]


=== TEST 3: Non existent params cannot be set
--- http_config eval
qq {
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";
init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
    local ok, err = pcall(require("ledge").configure, { foo = "bar" })
    assert(string.find(err, "field foo does not exist"),
        "error 'field foo does not exist' should be thrown")
}
}
--- config
location /ledge_3 {
    echo "OK";
}
--- request
GET /ledge_3
--- no_error_log
[error]


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
--- http_config eval
qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
    require("ledge").configure({
        redis_connector_params = {
            port = 0, -- bad port
        },
    })
}
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
--- error_log eval: qr/connect\(\)( to 127.0.0.1:0)? failed/


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
--- http_config eval
qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
    require("ledge").set_handler_defaults({
        storage_driver_config = {
            redis_connector_params = {
                port = 0,
            },
        }
    })
}
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
--- error_log eval: qr/connect\(\)( to 127.0.0.1:0)? failed/


=== TEST 9: Create qless connection
--- http_config eval: $::HttpConfig
--- config
location /ledge_9 {
    content_by_lua_block {
        local redis = assert(require("ledge").create_qless_connection(),
            "create_qless_connection() should return positively")

        assert(redis:set("ledge_9:cat", "dog"),
            "redis:set() should return positively")

        assert(require("ledge").close_redis_connection(redis),
            "close_redis_connection() should return positively")

        local redis = require("ledge").create_redis_connection()
        assert(redis:select(qless_db), "select() shoudl return positively")

        ngx.say(redis:get("ledge_9:cat"))

        assert(require("ledge").close_redis_connection(redis),
            "close_redis_connection() should return positively")
    }
}
--- request
GET /ledge_9
--- response_body
dog
--- no_error_log
[error]

=== TEST 10: Bad redis-connector params are caught
--- http_config eval
qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
    require("ledge").configure({
        redis_connector_params = {
            bad_time = true
        },
    })
    require("ledge").set_handler_defaults({
        storage_driver_config = {
            redis_connector_params = {
                bad_time2 = true
            },
        }
    })
}
}
--- config
location /ledge_10 {
    content_by_lua_block {
        local ok, err = require("ledge").create_redis_connection()
        assert(ok == nil and err ~= nil,
            "create_redis_connection() should return negatively with error")

        local ok, err = require("ledge").create_storage_connection()
        assert(ok == nil and err ~= nil,
            "create_storage_connection() should return negatively with error")

        local ok, err = require("ledge").create_qless_connection()
        assert(ok == nil and err ~= nil,
            "create_qless_connection() should return negatively with error")

        local ok, err = require("ledge").create_redis_slave_connection()
        assert(ok == nil and err ~= nil,
            "create_redis_slave_connection() should return negatively with error")

        -- Test broken redis-connector params are caught when closing redis somehow
        local ok, err = require("ledge").close_redis_connection({dummy = true})
        assert(ok == nil and err ~= nil,
            "close_redis_connection() should return negatively with error")

        -- Test trying to close a non-existent redis instance
        local ok, err = require("ledge").close_redis_connection({})
        assert(ok == nil and err ~= nil,
            "close_redis_connection() should return negatively with error")

        ngx.say("OK")
    }
}
--- request
GET /ledge_10
--- error_code: 200
--- response_body
OK

=== TEST 11: Closing an empty redis instance
--- http_config eval: $::HttpConfig
--- config
location /ledge_11 {
    content_by_lua_block {
        local ok, err = require("ledge").close_redis_connection({})
        assert(ok == nil,
            "close_redis_connection() should return negatively")

        ngx.say("OK")
    }
}
--- request
GET /ledge_11
--- error_code: 200
--- response_body
OK
