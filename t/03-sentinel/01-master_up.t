use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} ||= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} ||= 3;
$ENV{TEST_LEDGE_SENTINEL_MASTER_NAME} ||= 'mymaster';
$ENV{TEST_LEDGE_SENTINEL_PORT} ||= 6381;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    local db = $ENV{TEST_LEDGE_REDIS_DATABASE}
    local qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE}
    local master_name = '$ENV{TEST_LEDGE_SENTINEL_MASTER_NAME}'
    local sentinel_port = $ENV{TEST_LEDGE_SENTINEL_PORT}

    local redis_connector_params = {
        url = "sentinel://" .. master_name .. ":m/" .. tostring(db),
        sentinels = {
            { host = "127.0.0.1", port = sentinel_port },
        },
    }

    require("ledge").configure({
        redis_connector_params = redis_connector_params,
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = redis_connector_params,
        }
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
}

};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /sentinel_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /sentinel_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- request
GET /sentinel_1_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 2: create_redis_slave_connection
--- http_config eval: $::HttpConfig
--- config
location /sentinel_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local slave, err = require("ledge").create_redis_slave_connection()
        assert(slave and not err,
            "create_redis_slave_connection should return positively")

        assert(slave:role()[1] == "slave", "role should be slave")
    }
}
--- request
GET /sentinel_1_prx
--- no_error_log
[error]


=== TEST 4a: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /sentinel_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /sentinel_3 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- request
GET /sentinel_3_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 3: Wildcard Purge (scan on slave)
--- http_config eval: $::HttpConfig
--- config
location /sentinel_3 {
    content_by_lua_block {
        require("ledge").create_handler({
            keyspace_scan_count = 1,
        }):run()
    }
}
--- request
PURGE /sentinel_3*
--- wait: 1
--- no_error_log
[error]
--- error_code: 200
