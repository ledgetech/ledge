use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    require("ledge").set_handler_defaults({
        keep_cache_for = 0,
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
}

};

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
    echo_sleep 0.05;
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
        local key_chain = handler:cache_key_chain()
        local num_entities, err = redis:scard(key_chain.entities)
        ngx.say(num_entities)
    }
}
location /gc {
    more_set_headers "Cache-Control: public, max-age=5";
    echo "UPDATED";
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
        local key_chain = require("ledge").create_handler():cache_key_chain()
        local res, err = redis:keys(key_chain.root .. "*")
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
        local key_chain = require("ledge").create_handler():cache_key_chain()
        local res, err = redis:keys(key_chain.root .. "*")
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
3
