use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 4;

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        cjson = require 'cjson'
        rack = require 'resty.rack'
        ledge = require 'ledge.ledge'
        ledge.gset('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ";
};

run_tests();

__DATA__
=== TEST 1: No calculated Age header on cache MISS.
--- http_config eval: $::HttpConfig
--- config
	location /age {
        content_by_lua '
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /age
--- response_headers
Age:


=== TEST 2: Age header on cache HIT
--- http_config eval: $::HttpConfig
--- config
	location /age {
        content_by_lua '
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /age
--- response_headers_like
Age: \d+
