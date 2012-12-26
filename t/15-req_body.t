use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

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
=== TEST 1: Should pass through request body
--- http_config eval: $::HttpConfig
--- config
location /cached {
    content_by_lua '

        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.req.read_body()
        ngx.say({ngx.req.get_body_data()})
    ';
}
--- request
POST /cached
requestbody
--- response_body
requestbody
