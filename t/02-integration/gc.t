use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_nginx_config => qq{
    lua_check_client_abort on;
}, extra_lua_config => qq{
    require("ledge").set_handler_defaults({
        keep_cache_for = 0,
    })
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /gc_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /gc {
    more_set_headers "Cache-Control: public, max-age=60";
    echo "OK";
}
--- request
GET /gc_prx
--- no_error_log
[error]
--- response_body
OK


=== TEST 2: Force revaldation (creates new entity)
--- http_config eval: $::HttpConfig
--- config
location /gc_prx {
    rewrite ^(.*)_prx$ $1 break;
    echo_location_async '/gc_a';
    echo_sleep 0.1;
    echo_location_async '/gc_b';
    echo_sleep 2.5;
}
location /gc_a {
    rewrite ^(.*)_a$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run();
    }
}
location /gc_b {
    rewrite ^(.*)_b$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis

        local key_chain = handler:cache_key_chain()
        local num_entities, err = redis:scard(key_chain.entities)
        ngx.say(num_entities)
    }
}
location /gc {
    more_set_headers "Cache-Control: public, max-age=5";
    content_by_lua_block {
        ngx.say("UPDATED")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /gc_prx
--- response_body
UPDATED
1
--- wait: 1


=== TEST 3: Check we now have just one entity
--- http_config eval: $::HttpConfig
--- config
location /gc {
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis

        local key_chain = handler:cache_key_chain()
        local num_entities, err = redis:scard(key_chain.entities)
        ngx.say(num_entities)
    }
}
--- request
GET /gc
--- no_error_log
[error]
--- response_body
1
--- wait: 2


=== TEST 4: Entity will have expired, check Redis has cleaned up all keys.
--- http_config eval: $::HttpConfig
--- config
location /gc {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local key_chain = handler:cache_key_chain()
        local res, err = redis:keys(key_chain.full .. "*")
        assert(not next(res), "res should be empty")
    }
}
--- request
GET /gc
--- no_error_log
[error]


=== TEST 5: Prime cache
--- http_config eval: $::HttpConfig
--- config
location /gc_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /gc_5 {
    more_set_headers "Cache-Control: public, max-age=60";
    echo "OK";
}
--- request
GET /gc_5_prx
--- no_error_log
[error]
--- response_body
OK


=== TEST 5b: Delete one part of the key chain
Simulate eviction under memory pressure. Will cause a MISS.
--- http_config eval: $::HttpConfig
--- config
location /gc_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local key_chain = handler:cache_key_chain()
        redis:del(key_chain.headers)
        handler:run()
    }
}
location /gc_5 {
    more_set_headers "Cache-Control: public, max-age=60";
    echo "OK 2";
}
--- request
GET /gc_5_prx
--- wait: 3
--- no_error_log
[error]
--- response_body
OK 2


=== TEST 5c: Missing keys should cause colleciton of the old entity.
--- http_config eval: $::HttpConfig
--- config
location /gc_5 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local key_chain = handler:cache_key_chain()
        local res, err = redis:keys(key_chain.full .. "*")
        if res then
            ngx.say(#res)
        end
    }
}
--- request
GET /gc_5
--- no_error_log
[error]
--- response_body
5
