use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 31;

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

=== TEST 3b: No-cache request with extension; X-Cache: MISS
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
            ngx.say("TEST 3b")
        ';
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=1234
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3b


=== TEST 3c: No-store request; X-Cache: MISS
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
            ngx.say("TEST 3c")
        ';
    }
--- more_headers
Cache-Control: no-store
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 3c


=== TEST 4a: PURGE
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
            ngx.say("TEST 4")
        ';
    }
--- request
PURGE /cache
--- error_code: 200


=== TEST 4: Cold request (expired but known); X-Cache: MISS
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


=== TEST 7: only-if-cached should return 504 on cache miss
--- http_config eval: $::HttpConfig
--- config
    location /cache_7 {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.say("TEST 7")
        ';
    }
--- more_headers
Cache-Control: only-if-cached
--- request
GET /cache_7
--- error_code: 504

=== TEST 8: min-fresh reduces calculated ttl
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.say("TEST 8")
        ';
    }
--- more_headers
Cache-Control: min-fresh=9999
--- request
GET /cache
--- response_body
TEST 8

=== TEST 9a: Prime a 404 response into cache; X-Cache: MISS
--- http_config eval: $::HttpConfig
--- config
    location /cache_9 {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.status = ngx.HTTP_NOT_FOUND
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("TEST 9")
        ';
    }
--- request
GET /cache_9
--- response_headers_like
X-Cache: MISS from .*
--- response_body
TEST 9
--- error_code: 404


=== TEST 9b: Test we still have 404; X-Cache: HIT
--- http_config eval: $::HttpConfig
--- config
    location /cache_9 {
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /cache_9
--- response_headers_like
X-Cache: HIT from .*
--- response_body
TEST 9
--- error_code: 404
