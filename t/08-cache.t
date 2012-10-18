use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3); 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
};

run_tests();

__DATA__
=== TEST 1: Subzero request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 1")
        ';
    }
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 1


=== TEST 2: Hot request; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        echo "TEST 2";
    }
--- request
GET /cache
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 1


=== TEST 3: No-cache request; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 3")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3


=== TEST 4: Cold request (expired but known); X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            local resty_redis = require "resty.redis"
            local redis = resty_redis:new()

            redis:connect(ledge:config_get("redis_host"), ledge:config_get("redis_port"))
            redis:select(ledge:config_get("redis_database"))

            -- Hack the expires to 100 seconds in the past
            redis:hset(ledge:cache_key(), "expires", tostring(ngx.time() - 100))
            redis:close()
            
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 4")
        ';
    }
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 4


=== TEST 6: Non-cacheable response (no X-*-Cache headers).
--- http_config eval: $::HttpConfig
--- config
    location /cache_6 {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "no-cache"
            ngx.say("TEST 6")
        ';
    }
--- request
GET /cache_6
--- response_headers_like
X-Cache: 
--- response_body
TEST 6


