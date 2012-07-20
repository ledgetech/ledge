use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
my $pwd = cwd();

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
=== TEST 1: ORIGIN_MODE_NORMAL
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode {
        content_by_lua '
            ledge.set("origin_mode", ledge.ORIGIN_MODE_NORMAL)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        more_set_headers  "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /origin_mode
--- response_body
OK


=== TEST 2: ORIGIN_MODE_OFFLINE
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode {
        content_by_lua '
            ledge.set("origin_mode", ledge.ORIGIN_MODE_OFFLINE)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        echo "ORIGIN";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode
--- response_body
OK


=== TEST 3: ORIGIN_MODE_MAINTENANCE when cached
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode {
        content_by_lua '
            ledge.set("origin_mode", ledge.ORIGIN_MODE_MAINTENANCE)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        echo "ORIGIN";
    }
    location /__ledge_maintenance {
        echo "FAIL WHALE";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode
--- response_body
OK

=== TEST 4: ORIGIN_MODE_MAINTENANCE when we have nothing
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_maintenance {
        content_by_lua '
            ledge.set("origin_mode", ledge.ORIGIN_MODE_MAINTENANCE)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        echo "ORIGIN";
    }
    location /__ledge_maintenance {
        more_set_headers  "Cache-Control public, max-age=600";
        echo "FAIL WHALE";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_maintenance
--- response_body
FAIL WHALE

=== TEST 5: ORIGIN_MODE_MAINTENANCE check we don't cache the fail whale.
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_maintenance {
        content_by_lua '
            ledge.set("origin_mode", ledge.ORIGIN_MODE_MAINTENANCE)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        echo "ORIGIN";
    }
    location /__ledge_maintenance {
        echo "FAIL WHALE CHANGED";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_maintenance
--- response_body
FAIL WHALE CHANGED
