use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = TEST_NGINX_PORT,
    })

    require("ledge.state_machine").set_debug(true)
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: create_purge_response
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local cjson_decode = require("cjson").decode

        local create_purge_response = assert(
            require("ledge.purge").create_purge_response,
            "module should load without errors"
        )

        local json, err = create_purge_response("invalidate", "purged")
        local data = cjson_decode(json)

        assert(not err, "err should be nil")

        assert(data.purge_mode == "invalidate",
            "purge mode should be invalidate")

        assert(data.result == "purged",
            "result should be purged")

        assert(not data.qless_job, "qless_job should be nil")


        local json, err = create_purge_response("revalidate", "scheduled", {
            jid = "12345",
        })
        local data = cjson_decode(json)

        assert(not err, "err should be nil")

        assert(data.qless_job.jid == "12345",
            "qless_job.jid should be '12345'")


        local json, err = create_purge_response(function() end)
        assert(err == "Cannot serialise function: type not supported",
            "error should be 'Cannot serialise function: type not supported")
    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 2: expire keys
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis   = require("ledge").create_redis_connection()
        handler.redis = redis

        local storage = require("ledge").create_storage_connection(
                handler.config.storage_driver,
                handler.config.storage_driver_config
            )
        handler.storage = storage

        local key_chain = handler:cache_key_chain()
        local entity_id = handler:entity_id(key_chain)

        local ttl, err = redis:ttl(key_chain.main)

        local expire_keys = require("ledge.purge").expire_keys

        local ok, err = expire_keys(redis, storage, key_chain, entity_id)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok, "expire_keys should return positively")

        local expires, err = redis:hget(key_chain.main, "expires")
        ngx.log(ngx.DEBUG,"expires: ", expires, " <= ", ngx.now())
        assert(tonumber(expires) <= ngx.now(), "Key not expired")

        local new_ttl = redis:ttl(key_chain.main)
        ngx.log(ngx.DEBUG, "ttl: ", tonumber(ttl), " > ", tonumber(new_ttl))
        assert(tonumber(ttl) > tonumber(new_ttl), "TTL not reduced")

        -- non-existent key
        local ok, err = expire_keys(redis, storage, {main = "bogus_key"}, entity_id)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == nil, "return false with no error on missing key")

        -- Stub out a partial main key, no ttl
        redis:hset("bogus_key", "key", "value")

        local ok, err = expire_keys(redis, storage, {main = "bogus_key"}, entity_id)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == nil and err ~= nil, "return nil with no ttl")

        -- Set a TTL
        redis:expire("bogus_key", 9000)

        local ok, err = expire_keys(redis, storage, {main = "bogus_key"}, entity_id)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == nil and err ~= nil, "return nil with error on broken key")

        -- String expires value
        redis:hset("bogus_key", "expires", "now!")

        local ok, err = expire_keys(redis, storage, {main = "bogus_key"}, entity_id)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == nil and err ~= nil, "return nil with error on string expires")
    }
}
location /cache_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", function(res)
            ngx.log(ngx.DEBUG, "primed entity: ", res.entity_id)
        end)
        handler:run()
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
    }
}
--- request eval
[
"GET /cache_prx",
"GET /t"
]
--- no_error_log
[error]

=== TEST 3: purge
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache3 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis   = require("ledge").create_redis_connection()
        handler.redis = redis

        local storage = require("ledge").create_storage_connection(
                handler.config.storage_driver,
                handler.config.storage_driver_config
            )
        handler.storage = storage

        local key_chain = handler:cache_key_chain()

        local purge = require("ledge.purge").purge

        -- invalidate - error
        local ok, err = purge(handler, "invalidate", {main = "bogus_key"})
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "nothing to purge", "purge should return false - bad key")

        -- invalidate
        local ok, err = purge(handler, "invalidate", key_chain)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == true and err == "purged", "purge should return true - purged")

        -- revalidate
        local reval_job = false
        handler.revalidate_in_background = function()
            reval_job = true
            return "job"
        end

        local ok, err, job = purge(handler, "revalidate", key_chain)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "already expired", "purge should return false - already expired")
        assert(reval_job == true, "revalidate should schedule job")
        assert(job == "job", "revalidate should return the job "..tostring(job))

        -- delete, error
        handler.delete_from_cache = function() return nil, "delete error" end
        local ok, err = purge(handler, "delete", key_chain)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == nil and err == "delete error", "purge should return nil, error")
        handler.delete_from_cache = require("ledge.handler").delete_from_cache

        -- delete
        local ok, err = purge(handler, "delete", key_chain)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == true and err == "deleted", "purge should return true - deleted")

        -- delete, missing
        local ok, err = purge(handler, "delete", key_chain)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "nothing to purge", "purge should return false - nothing to purge")
    }
}
location /cache3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:run()
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    }
}
--- request eval
[
"GET /cache3_prx",
"GET /t"
]
--- no_error_log
[error]
