use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2); 

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
=== TEST 1: Update response provided to closure
--- http_config eval: $::HttpConfig
--- config
location /events_1 {
    content_by_lua '
        ledge:bind("response_ready", function(res)
            res.body = "UPDATED"
        end)
        ledge:run()
    ';
}
location /__ledge_origin {
    echo "ORIGIN";
}
--- request
GET /events_1
--- response_body: UPDATED

