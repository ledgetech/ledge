use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3); 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_use_sentinel', true)
        ledge:config_set('redis_sentinel_master_name', '$ENV{TEST_LEDGE_SENTINEL_MASTER_NAME}')
        ledge:config_set('redis_sentinels', {
            { host = '127.0.0.1', port = $ENV{TEST_LEDGE_SENTINEL_PORT} }, 
        })
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
};

run_tests();

__DATA__
=== TEST 1: Prime cache
--- http_config eval: $::HttpConfig
--- config
	location /sentinel_1 {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        content_by_lua '
            ngx.header["Cache-Control"] = "max-age=3600"
            ngx.say("OK")
        ';
    }
--- request
GET /sentinel_1
--- no_error_log
[error]
--- response_body
OK

