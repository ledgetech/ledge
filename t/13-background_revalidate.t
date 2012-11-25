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
        ledge:config_set('background_revalidate', true)
        ledge:config_set('max_stale', 99999)
	";
};


run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale {
    content_by_lua '

        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale
--- response_body
TEST 1


=== TEST 2: Return stale
--- http_config eval: $::HttpConfig
--- config
location /stale {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 2")
    ';
}
--- request
GET /stale
--- response_body
TEST 1


=== TEST 3: Cache has been revalidated
--- http_config eval: $::HttpConfig
--- config
location /stale {
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
GET /stale
--- response_body
TEST 2
