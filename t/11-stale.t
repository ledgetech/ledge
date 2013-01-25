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

our $StaleHttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('max_stale', 1000)
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


=== TEST 2: Honour max-stale request header
--- http_config eval: $::HttpConfig
--- config
location /stale {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 2")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale
--- response_body
TEST 1


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


=== TEST 3: Honour max_stale ledge config option
--- http_config eval: $::StaleHttpConfig
--- config
location /stale {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 3")
    ';
}
--- request
GET /stale
--- response_body
TEST 1


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


=== TEST 4: max_stale config overrides request header
--- http_config eval: $::StaleHttpConfig
--- config
location /stale {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 4")
    ';
}
--- more_headers
Cache-Control: max-stale=0
--- request
GET /stale
--- response_body
TEST 1


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


=== TEST 5: Stale responses should set Warning header
--- http_config eval: $::StaleHttpConfig
--- config
location /stale {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 5")
    ';
}
--- request
GET /stale
--- response_headers_like
Warning: 110 .*


=== TEST 5: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_s {
    content_by_lua '

        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "s-maxage=0"
        end)
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "s-maxage=3600"
        ngx.say("TEST 5")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_s
--- response_body
TEST 5


=== TEST 6: s-maxage prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_s {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 6")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_s
--- response_body
TEST 6


=== TEST 7: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_pv {
    content_by_lua '

        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, proxy-revalidate"
        end)
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, proxy-revalidate"
        ngx.say("TEST 7")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_pv
--- response_body
TEST 7


=== TEST 8: proxy-revalidate prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_pv {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 8")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_pv
--- response_body
TEST 8


=== TEST 9: Reset cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /stale_mv {
    content_by_lua '

        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0, must-revalidate"
        end)
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600, must-revalidate"
        ngx.say("TEST 9")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /stale_mv
--- response_body
TEST 9


=== TEST 10: must-revalidate prevents serving stale
--- http_config eval: $::HttpConfig
--- config
location /stale_mv {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 10")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_mv
--- response_body
TEST 10


=== TEST 11: Do not attempt to serve stale with no cache entry
--- http_config eval: $::HttpConfig
--- config
location /stale_subzero {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("TEST 11")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_subzero
--- response_body
TEST 11
