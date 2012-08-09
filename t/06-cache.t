use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4); 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		rack = require 'resty.rack'
		ledge = require 'ledge.ledge'
		ledge.gset('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
};

run_tests();

__DATA__
=== TEST 1: Subzero request; X-Cache: MISS / X-Ledge-Cache: SUBZERO
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            rack.use(ledge)
            rack.run()
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
X-Ledge-Cache: SUBZERO from .*
--- response_body
TEST 1


=== TEST 2: Hot request; X-Cache: HIT / X-Ledge-Cache: HOT
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            rack.use(ledge)
            rack.run()
        ';
    }

    location /__ledge_origin {
        echo "TEST 2";
    }
--- request
GET /cache
--- response_headers_like
X-Cache: HIT from .*
X-Ledge-Cache: HOT from .*
--- response_body
TEST 1


=== TEST 3: No-cache request; X-Cache: MISS / X-Ledge-Cache: IGNORED
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            rack.use(ledge)
            rack.run()
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
X-Ledge-Cache: IGNORED from .*
--- response_body
TEST 3


=== TEST 4: Cold request (expired but known); X-Cache: MISS / X-Ledge-Cache: COLD
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            local resty_redis = require "resty.redis"
            local redis = resty_redis:new()
            redis:connect(ledge.get("redis_host"), ledge.get("redis_port"))
            redis:select(ledge.get("redis_database"))

            -- Hack the expires to 100 seconds in the past
            redis:hset(ledge.cache_key(), "expires", tostring(ngx.time() - 100))
            redis:close()

            rack.use(ledge)
            rack.run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600, must-revalidate"
            ngx.say("TEST 4")
        ';
    }
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
X-Ledge-Cache: COLD from .*
--- response_body
TEST 4


=== TEST 5: X-Cache: MISS / X-Ledge-Cache: REVALIDATED
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            rack.use(ledge)
            rack.run()
        ';
    }

    location /__ledge_origin {
        echo "TEST 5";
    }
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
X-Ledge-Cache: REVALIDATED from .*
--- response_body
TEST 5
