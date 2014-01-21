use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
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
        echo_sleep 2;
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
           local cache_key = ledge:cache_key()
           local num_entities, err = redis:zcard(cache_key .. ":entities")
           ngx.say(num_entities)
           local memused  = redis:get(cache_key .. ":memused")
           ngx.say(memused)
        ';
    }
    location /gc {
        more_set_headers "Cache-Control: public, max-age=60";
        echo "UPDATED";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /gc_prx
--- no_error_log
--- response_body
UPDATED
2
11


=== TEST 3: Check we now have just one entity, and memused is reduced by 3 bytes.
--- http_config eval: $::HttpConfig
--- config
    location /gc {
        content_by_lua '
           local redis_mod = require "resty.redis"
           local redis = redis_mod.new()
           redis:connect("127.0.0.1", 6379)
           local cache_key = ledge:cache_key()
           local num_entities, err = redis:zcard(cache_key .. ":entities")
           ngx.say(num_entities)
           local memused  = redis:get(cache_key .. ":memused")
           ngx.say(memused)
        ';
    }
--- request
GET /gc
--- no_error_log
--- response_body
1
8

