use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 1;

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

    local ledge = require("ledge")

    ledge.set("redis_params", {
        redis_connector = {
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
        assert(require("ledge"))
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
    require("ledge").set("foo", "bar")
}
--- config
location /ledge_3 {
    echo "OK";
}
--- request
GET /ledge_3
--- error_log
attempt to create new field foo
--- must_die


=== TEST 3b: Non existent sub-params cannot be set
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";
init_by_lua_block {
    require("ledge").set("redis_params", { foo = "bar" })
}
--- config
location /ledge_3 {
    echo "OK";
}
--- request
GET /ledge_3
--- error_log
attempt to create new field foo
--- must_die


=== TEST 4: Params cannot be set outside of init
--- http_config eval: $::HttpConfig
--- config
location /ledge_4 {
    content_by_lua_block {
        local ledge = require("ledge")
        ledge.set("foo", bar)
    }
}
--- request
GET /ledge_4
--- error_log
attempt to set params outside of the 'init' phase
--- error_code: 500


=== TEST 5: Create redis connection
--- http_config eval: $::HttpConfig
--- config
location /ledge_5 {
    content_by_lua_block {
        local redis = assert(require("ledge").create_redis_connection())
        assert(redis:set("ledge_5:cat", "dog"))
        ngx.say(redis:get("ledge_5:cat"))
        assert(redis:close())
    }
}
--- request
GET /ledge_5
--- response_body
dog
--- no_error_log
[error]
--- error_code: 200


=== TEST 6: Create bad redis connection
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

init_by_lua_block {
    require("ledge").set("redis_params", {
        redis_connector = {
            port = 0, -- bad port
        },
    })
}
--- config
location /ledge_6 {
    content_by_lua_block {
        assert(require("ledge").create_redis_connection())
    }
}
--- request
GET /ledge_6
--- error_log
Connection refused
--- error_code: 500
