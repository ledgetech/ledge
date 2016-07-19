use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('keep_cache_for', 0)
    ";

    init_worker_by_lua "
        ledge:run_workers()
    ";
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
        content_by_lua '
            ledge:run()
        ';
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
        content_by_lua '
            ledge:run();
        ';
    }
    location /gc_b {
        rewrite ^(.*)_b$ $1 break;
        content_by_lua '
           local redis_mod = require "resty.redis"
           local redis = redis_mod.new()
           redis:connect("127.0.0.1", 6379)
           redis:select(ledge:config_get("redis_database"))
           local key_chain = ledge:cache_key_chain()
           local num_entities, err = redis:zcard(key_chain.entities)
           ngx.say(num_entities)
           local memused  = redis:get(key_chain.memused)
           ngx.say(memused)
        ';
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
2
11


=== TEST 3: Check we now have just one entity, and memused is reduced by 3 bytes.
--- http_config eval: $::HttpConfig
--- config
    location /gc {
        content_by_lua '
            ngx.sleep(1) -- Wait for qless to do the work

            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_database"))
            local key_chain = ledge:cache_key_chain()
            local num_entities, err = redis:zcard(key_chain.entities)
            ngx.say(num_entities)
            local memused  = redis:get(key_chain.memused)
            ngx.say(memused)
        ';
    }
--- request
GET /gc
--- timeout: 4
--- no_error_log
[error]
--- response_body
1
8


=== TEST 4: Entity will have expired, check Redis has cleaned up all keys.
--- http_config eval: $::HttpConfig
--- config
    location /gc {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ngx.sleep(4)
            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_database"))
            local key_chain = ledge:cache_key_chain()

            local res, err = redis:keys(key_chain.root .. "*")
            if res then
                for i,v in ipairs(res) do
                    ngx.say(v)
                end
            end
        ';
    }
--- request
GET /gc
--- timeout: 6
--- no_error_log
[error]
--- response_body


=== TEST 5: Prime cache
--- http_config eval: $::HttpConfig
--- config
    location /gc_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
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


=== TEST 5b: Delete one part of the key chain (simulate eviction under memory pressure). Will cause a MISS.
--- http_config eval: $::HttpConfig
--- config
    location /gc_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_database"))
            local key_chain = ledge:cache_key_chain()
            local entity = redis:get(key_chain.key)
            local entity_keys = ledge.entity_keys(key_chain.root .. "::" .. entity)

            redis:del(key_chain.entities)
            redis:del(entity_keys.body)

            ledge:run()
        ';
    }
    location /gc_5 {
        more_set_headers "Cache-Control: public, max-age=60";
        echo "OK 2";
    }
--- request
GET /gc_5_prx
--- no_error_log
[error]
--- response_body
OK 2


=== TEST 5c: Missing keys should cause colleciton of the remaining keys. Confirm they are gone.
--- http_config eval: $::HttpConfig
--- config
    location /gc_5 {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ngx.sleep(4)
            local redis_mod = require "resty.redis"
            local redis = redis_mod.new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get("redis_database"))
            local key_chain = ledge:cache_key_chain()

            local res, err = redis:keys(key_chain.root .. "*")
            if res then
                ngx.say(#res)
            end
        ';
    }
--- request
GET /gc_5
--- timeout: 6
--- no_error_log
[error]
--- response_body
9
