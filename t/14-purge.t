use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 6;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
};

run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /cached {
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
GET /cached
--- response_body
TEST 1


=== TEST 2: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /cached {
    content_by_lua '
        ledge:run()
    ';
}

--- request
PURGE /cached
--- error_code: 200

=== TEST 3: Cache has been purged
--- http_config eval: $::HttpConfig
--- config
location /cached {
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
--- request
GET /cached
--- response_body
TEST 3

=== TEST 4: Purge on unknown key returns 404
--- http_config eval: $::HttpConfig
--- config
location /foobar {
    content_by_lua '
        ledge:run()
    ';
}

--- request
PURGE /foobar
--- error_code: 404
