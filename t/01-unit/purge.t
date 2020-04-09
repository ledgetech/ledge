use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

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

        assert(not data.qless_jobs, "qless_jobs should be nil")


        local json, err = create_purge_response("revalidate", "scheduled", {
            jid = "12345",
        })
        local data = cjson_decode(json)

        assert(not err, "err should be nil")

        assert(data.qless_jobs.jid == "12345",
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
        ngx.log(ngx.DEBUG, require("cjson").encode(key_chain))

        local purge = require("ledge.purge").purge

        -- invalidate - error
        local ok, err = purge(handler, "invalidate",  "bad_key")
        --local ok, err = purge(handler, "invalidate", {main = "bogus_key3"})
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "nothing to purge", "purge should return false - bad key")

        -- invalidate
        local ok, err = purge(handler, "invalidate", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == true and err == "purged", "purge should return true - purged")

        -- revalidate
        local reval_job = false
        handler.revalidate_in_background = function()
            reval_job = true
            return "job"
        end

        local ok, err, job = purge(handler, "revalidate", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "already expired", "purge should return false - already expired")
        assert(reval_job == true, "revalidate should schedule job")
        assert(job[1] == "job", "revalidate should return the job "..tostring(job))

        -- delete, error
        handler.delete_from_cache = function() return nil, "delete error" end
        local ok, err = purge(handler, "delete", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == nil and err == "delete error", "purge should return nil, error")
        handler.delete_from_cache = require("ledge.handler").delete_from_cache

        -- delete
        local ok, err = purge(handler, "delete", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, "dekete: ",err) end
        assert(ok == true and err == "deleted", "purge should return true - deleted")

        -- delete, missing
        local ok, err = purge(handler, "delete", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "nothing to purge", "purge should return false - nothing to purge")

        local keys = redis:keys(key_chain.root.."*")
        ngx.log(ngx.DEBUG, require("cjson").encode(keys))

        assert(#keys == 0, "Keys have all been removed")
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

=== TEST 3b: purge with vary
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
        ngx.log(ngx.DEBUG, require("cjson").encode(key_chain))

        local purge = require("ledge.purge").purge

        -- invalidate
        local ok, err = purge(handler, "invalidate", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == true and err == "purged", "purge should return true - purged")

        -- revalidate
        local reval_job = false
        local jobcount = 0
        handler.revalidate_in_background = function()
            jobcount = jobcount + 1
            reval_job = true
            return "job"..jobcount
        end

        local ok, err, job = purge(handler, "revalidate", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, err) end
        assert(ok == false and err == "already expired", "purge should return false - already expired")
        assert(reval_job == true, "revalidate should schedule job")
        assert(job[1] == "job1" and job[2] == "job2", "revalidate should return the job "..tostring(job))
        assert(jobcount == 2, "Revalidate should schedule 1 job per representation")

        -- delete
        local ok, err = purge(handler, "delete", key_chain.repset)
        if err then ngx.log(ngx.DEBUG, "dekete: ",err) end
        assert(ok == true and err == "deleted", "purge should return true - deleted")


        local keys = redis:keys(key_chain.root.."*")
        ngx.log(ngx.DEBUG, require("cjson").encode(keys))

        assert(#keys == 0, "Keys have all been removed")
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
        ngx.header["Vary"] = "X-Test"
        ngx.say("TEST 3b")
    }
}
--- request eval
[
"GET /cache3_prx", "GET /cache3_prx",
"GET /t"
]
--- more_headers eval
[
"X-Test: foo", "X-Test: bar",
""
]
--- no_error_log
[error]

=== TEST 4: purge api
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^ /cache4 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis   = require("ledge").create_redis_connection()
        handler.redis = redis

        local storage = require("ledge").create_storage_connection(
                handler.config.storage_driver,
                handler.config.storage_driver_config
            )
        handler.storage = storage

        -- Stub out response object
        local response = {
            status = 0,
            body,
            set_body = function(self, body)
                self.body = body
            end
        }
        handler.response = response

        local json_body = nil

        ngx.req.get_body_data = function()
            return json_body
        end

        local purge_api = require("ledge.purge").purge_api

        -- Nil body
        local ok, err = purge_api(handler)
        if response.body then ngx.log(ngx.DEBUG, response.body) end
        assert(ok == false and response.body ~= nil, "nil body should return false")
        response.body = nil

        -- Invalid json
        json_body = [[ foobar  ]]
        local ok, err = purge_api(handler)
        if response.body then ngx.log(ngx.DEBUG, response.body) end
        assert(ok == false and response.body ~= nil, "invalid json should return false")
        response.body = nil

        -- Valid json, bad request
        json_body = [[{"foo": "bar"}]]
        local ok, err = purge_api(handler)
        if response.body then ngx.log(ngx.DEBUG, response.body) end
        assert(ok == false and response.body ~= nil, "bad request should return false")
        response.body = nil

        -- Valid API request
        json_body = require("cjson").encode({
            uris = {
                "http://"..ngx.var.host..":"..ngx.var.server_port.."/cache4_prx"
            },
            purge_mode = "delete",
            headers = {
                ["X-Test"] = "Test Header"
            }
        })
        local ok, err = purge_api(handler)
        if response.body then ngx.log(ngx.DEBUG, response.body) end
        assert(ok == true and response.body ~= nil, "valid request should return true")
        response.body = nil

        local res, err = redis:exists(handler:cache_key_chain().main)
        if err then ngx_log(ngx.ERR, err) end
        assert(res == 0, "Key should have been removed")

        -- Custom headers should be added to request
        json_body = require("cjson").encode({
            uris = {
                "http://"..ngx.var.host..":"..ngx.var.server_port.."/hdr_test"
            },
            purge_mode = "delete",
            headers = {
                ["X-Test"] = "Test Header"
            }
        })
        local ok, err = purge_api(handler)
        if response.body then ngx.log(ngx.DEBUG, response.body) end
        local match = response.body:find("X-Test: Test Header")
        assert(ok == true and match ~= nil, "custom header s should pass through")
        response.body = nil
    }
}
location /cache4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        local handler = require("ledge").create_handler()
        handler:run()
    }
}

location /hdr_test {
    content_by_lua_block {
        ngx.print(ngx.DEBUG, "X-Test: ", ngx.req.get_headers()["X-Test"])
    }
}

location /cache {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=4600"
        ngx.say("TEST 4")
    }
}
--- request eval
[
"GET /cache4_prx",
"GET /t"
]
--- no_error_log
[error]
