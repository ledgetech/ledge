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
        local redis = require("ledge").create_redis_connection()
        redis:flushall() -- Previous tests create some odd keys

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


=== TEST 2: Revalidate
Prime, Purge, revalidate
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache2 break;
    content_by_lua_block {
        local revalidate = require("ledge.jobs.revalidate")
        local redis = require("ledge").create_redis_connection()

        local handler = require("ledge").create_handler()
        handler.redis = redis


        local job = {
            redis = redis,
            data = {
                key_chain = handler:cache_key_chain()
            }
        }


        local ok, err, msg = revalidate.perform(job)
        assert(err == nil, "revalidate should not return an error")

        assert(ngx.shared.ledge_test:get("test2") == "Revalidate Request received",
                "Revalidate request was not received!"
            )


        redis:del(job.data.key_chain.reval_req_headers)
        local ok, err, msg = revalidate.perform(job)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")

        redis:del(job.data.key_chain.reval_params)
        local ok, err, msg = revalidate.perform(job)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")
    }
}
location /cache2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:run()
    }
}

location /cache2 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=10"
        ngx.print("TEST 2")
        if string.find(ngx.req.get_headers().user_agent, "revalidate", 1, true) then
            ngx.shared.ledge_test:set("test2", "Revalidate Request received")
        end
    }
}
--- request eval
[
"GET /cache2_prx",
"PURGE /cache2_prx",
"GET /t"
]
--- no_error_log
[error]

=== TEST 3: Revalidate - inline params
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local revalidate = require("ledge.jobs.revalidate")

        local job = {
            data = {
                reval_params =  {
                    server_addr = ngx.var.server_addr,
                    server_port = ngx.var.server_port,
                    scheme = ngx.var.scheme,
                    uri = "/cache3",
                    connect_timeout = 1000,
                    send_timeout = 1000,
                    read_timeout = 1000,
                    keepalive_timeout = 60,
                    keepalive_poolsize = 10,
                },
                reval_headers = {
                    ["X-Test"] = "test_header"
                }
            }
        }

        local ok, err, msg = revalidate.perform(job)
        assert(err == nil, "revalidate should not return an error")

        assert(ngx.shared.ledge_test:get("test3") == "test_header",
                "Revalidate request was not received!"
            )

        local job = {
            data = {
                reval_params =  {
                    server_addr = ngx.var.server_addr,
                    server_port = ngx.var.server_port,
                    scheme = ngx.var.scheme,
                    uri = "/cache_slow",
                    connect_timeout = 1000,
                    send_timeout = 100,
                    read_timeout = 100,
                    keepalive_timeout = 60,
                    keepalive_poolsize = 10,
                },
                reval_headers = {
                    ["X-Test"] = "test_header"
                }
            }
        }

        local ok, err, msg = revalidate.perform(job)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")

        local job = {
            data = {
                reval_params =  {
                    server_addr = ngx.var.server_addr,
                    server_port = ngx.var.server_port+1,
                    scheme = ngx.var.scheme,
                    uri = "/cache3",
                    connect_timeout = 1000,
                    send_timeout = 1000,
                    read_timeout = 1000,
                    keepalive_timeout = 60,
                    keepalive_poolsize = 10,
                },
                reval_headers = {
                    ["X-Test"] = "test_header"
                }
            }
        }

        local ok, err, msg = revalidate.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")

        local job = {
            redis = {
                hgetall = function(...) return ngx.null end
            },
            data = {
                key_chain = {}
            }
        }

        local ok, err, msg = revalidate.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")

        local job = {
            redis = {
                hgetall = function(...) return nil, "dummy error" end
            },
            data = {
                key_chain = {}
            }
        }

        local ok, err, msg = revalidate.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "revalidate should return an error")
    }
}
location /cache3 {
    content_by_lua_block {
        ngx.shared.ledge_test:set("test3", ngx.req.get_headers()["X-Test"])
    }
}
location /cache_slow {
    content_by_lua_block{
        ngx.sleep(1)
        ngx.print("OK")
    }
}
--- request
GET /t
--- error_code: 200

=== TEST 4: purge
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache break;
    content_by_lua_block {
        local purge_job = require("ledge.jobs.purge")
        local redis = require("ledge").create_redis_connection()

        local handler = require("ledge").create_handler()
        handler.redis = redis
        local heartbeat_flag = false

        local job = {
            redis = redis,
            data = {
                key_chain = { repset = "*::repset" },
                keyspace_scan_count = 2,
                purge_mode = "invalidate",
                storage_driver = handler.config.storage_driver,
                storage_driver_config = handler.config.storage_driver_config,
            },
            ttl       = function() return 5 end,
            heartbeat = function()
                heartbeat_flag = true
                return heartbeat_flag
            end,
        }

        -- Failure cases
        job.data.storage_driver = "bad"
        local ok, err, msg = purge_job.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "redis-error" and msg ~= nil, "purge should return redis-error")

        job.data.storage_driver = handler.config.storage_driver
        job.data.storage_driver_config = { bad_config = "here" }
        local ok, err, msg = purge_job.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "redis-error" and msg ~= nil, "purge should return redis-error")

        -- Passing case
        job.data.storage_driver_config = handler.config.storage_driver_config

        local ok, err, msg = purge_job.perform(job)
        assert(err == nil, "purge should not return an error")
        assert(heartbeat_flag == true, "Purge should heartbeat")

        -- Heartbeat failure
        job.heartbeat = function() return false end
        local ok, err, msg = purge_job.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "redis-error" and msg == "Failed to heartbeat job", "purge should return heartbeat error")
        job.heartbeat = function() return true end

        -- Missing redis driver
        job.redis = nil
        local ok, err, msg = purge_job.perform(job)
        ngx.log(ngx.DEBUG, msg)
        assert(err == "job-error" and msg ~= nil, "purge should return job-error")


    }
}
location /cache4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler():run()
    }
}

location /cache4 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 4")
    }
}
--- request eval
[
"GET /cache4_prx","GET /cache4_prx?a=1","GET /cache4_prx?a=2","GET /cache4_prx?a=3","GET /cache4_prx?a=4","GET /cache4_prx?a=5",
"GET /t",
"GET /cache4_prx?a=3"
]
--- response_headers_like eval
["X-Cache: MISS from .*", "X-Cache: MISS from .*","X-Cache: MISS from .*","X-Cache: MISS from .*","X-Cache: MISS from .*","X-Cache: MISS from .*",
"",
"X-Cache: MISS from .*"]
--- no_error_log
[error]
