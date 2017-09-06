use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";

lua_shared_dict ledge_test 1m;

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

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
    })
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Collect entity
Prime cache then collect the entity
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache break;
    content_by_lua_block {
        local collect_entity = require("ledge.jobs.collect_entity")
        local handler = require("ledge").create_handler()

        local entity_id = ngx.shared.ledge_test:get("entity_id")
        ngx.log(ngx.DEBUG, "Collecting: ", entity_id)

        local job = {
            data = {
                entity_id = entity_id,
                storage_driver = handler.config.storage_driver,
                storage_driver_config = handler.config.storage_driver_config,
            }
        }
        local ok, err, msg = collect_entity.perform(job)
        assert(err == nil, "collect_entity should not return an error")

        local storage = require("ledge").create_storage_connection(
                handler.config.storage_driver,
                handler.config.storage_driver_config
            )
        local ok, err = storage:exists(entity_id)
        assert(ok == false, "Entity should not exist")

        -- Failure cases
        job.data.storage_driver = "bad"
        local ok, err, msg = collect_entity.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "collect_entity should return job-error")

        job.data.storage_driver = handler.config.storage_driver
        job.data.storage_driver_config = { bad_config = "here" }
        local ok, err, msg = collect_entity.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "collect_entity should return job-error")
    }
}
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            ngx.log(ngx.DEBUG, "primed entity: ", res.entity_id)
            ngx.shared.ledge_test:set("entity_id", res.entity_id)
        end)
        handler:run()
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    }
}
--- request eval
[
"GET /cache_prx",
"GET /t"
]
--- no_error_log
[error]
