use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 5); 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		rack = require 'resty.rack'
		ledge = require 'ledge.ledge'
		ledge.set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
};

run_tests();

__DATA__
=== TEST 1: Subzero request; X-Cache: MISS / X-Ledge-Cache: SUBZERO
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        set $ledge_origin_action 0;

        content_by_lua '
            -- Pass the ledge_origin_action logging var to a header for us to test.
            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
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
X-Ledge-Origin-Action: FETCHED
--- response_body
TEST 1


=== TEST 2: Hot request; X-Cache: HIT / X-Ledge-Cache: HOT
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        set $ledge_origin_action 0;
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
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
X-Ledge-Origin-Action: NONE
--- response_body
TEST 1


=== TEST 3: No-cache request; X-Cache: MISS / X-Ledge-Cache: RELOADED
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        set $ledge_origin_action 0;
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
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
X-Ledge-Cache: RELOADED from .*
X-Ledge-Origin-Action: FETCHED
--- response_body
TEST 3


=== TEST 4: Cold request (expired but known); X-Cache: MISS / X-Ledge-Cache: COLD
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        set $ledge_origin_action 0;
        content_by_lua '
            local resty_redis = require "resty.redis"
            local redis = resty_redis:new()
            redis:connect(ledge.get("redis_host"), ledge.get("redis_port"))
            redis:select(ledge.get("redis_database"))

            -- Hack the expires to 100 seconds in the past
            redis:hset(ledge.cache_key(), "expires", tostring(ngx.time() - 100))
            redis:close()

            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
            rack.use(ledge)
            rack.run()
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
X-Ledge-Cache: COLD from .*
X-Ledge-Origin-Action: FETCHED
--- response_body
TEST 4


=== TEST 6: Non-cacheable response (no X-*-Cache headers).
--- http_config eval: $::HttpConfig
--- config
    location /cache_6 {
        set $ledge_origin_action 0;
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
            rack.use(ledge)
            rack.run()
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
X-Ledge-Cache: 
X-Ledge-Origin-Action: FETCHED
--- response_body
TEST 6


=== TEST 7: HTTP 1.0 request with Pragma: no-cache; X-Cache: MISS, X-Ledge-Cache: RELOADED
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        set $ledge_origin_action 0;
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-Ledge-Origin-Action"] = ngx.var.ledge_origin_action
            end)
            rack.use(ledge)
            rack.run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 7")
        ';
    }
--- more_headers
Pragma: no-cache
--- request
GET /cache HTTP/1.0
--- response_headers_like
X-Cache: MISS from .*
X-Ledge-Cache: RELOADED from .*
X-Ledge-Origin-Action: FETCHED
--- response_body
TEST 7

