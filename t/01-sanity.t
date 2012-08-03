use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2); 

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
=== TEST 1: Load module without errors.
--- http_config eval: $::HttpConfig
--- config
	location /sanity_1 {
        echo "OK";
    }
--- request
GET /sanity_1
--- no_error_log
[error]

=== TEST 2: Run module using Rack without errors.
--- http_config eval: $::HttpConfig
--- config
	location /sanity_2 {
        content_by_lua '
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge_origin {
        echo "OK";
    }
--- request
GET /sanity_2
--- no_error_log
[error]
