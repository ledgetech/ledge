use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 1; 

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

=== TEST 2: Run module without errors, returning origin content.
--- http_config eval: $::HttpConfig
--- config
	location /sanity_2 {
        content_by_lua '
            ledge:go()
        ';
    }
    location /__ledge_origin {
        echo "OK";
    }
--- request
GET /sanity_2
--- no_error_log
[error]
--- response_body
OK
