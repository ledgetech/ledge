use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 3; 

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
=== TEST 1: Client abort.
--- http_config eval: $::HttpConfig
--- config
location /client_abort {
    lua_check_client_abort on;
    content_by_lua '
        local ok, err = ngx.on_abort(function()
           ngx.log(ngx.NOTICE, "on abort called")
           -- ngx.exit(499)
        end)
     --   if not ok then
       --     error("cannot set on_abort: " .. err)
       -- end
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.sleep(3)
        ngx.say("TEST 1")
    ';
}
--- request
GET /client_abort

--- timeout: 0.5
--- ignore_response
--- error_log
client prematurely closed connection
on abort called
