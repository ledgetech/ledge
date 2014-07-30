use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 6;

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
=== TEST 1: Multiple cache-control response headers, miss
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 1")
        ';
    }
--- request
GET /cache
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1

=== TEST 1b: Multiple cache-control response headers, hit
--- http_config eval: $::HttpConfig
--- config
    location /cache {
        content_by_lua '
            ledge:run()
        ';
    }

    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = { "public", "max-age=3600"}
            ngx.say("TEST 2")
        ';
    }
--- request
GET /cache
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
TEST 1
