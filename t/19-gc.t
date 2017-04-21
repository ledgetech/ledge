use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set("redis_connection", {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        })
        ledge:config_set("storage_connection", {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        })
        ledge:config_set("redis_qless_database", $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('keep_cache_for', 0)
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
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
           redis:select(ledge:config_get("redis_connection").db)
           local key_chain = ledge:cache_key_chain()
           local num_entities, err = redis:scard(key_chain.entities)
           ngx.say(num_entities)
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
1
--- wait: 1


