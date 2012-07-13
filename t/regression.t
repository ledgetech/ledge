use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 28;

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
};

$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

run_tests();


__DATA__
=== TEST 1: no event, no header (issue #12, #13, #14)
--- http_config eval: $::HttpConfig
--- config
	location /test {
		content_by_lua '
			local rack = require "resty.rack"
			local ledge = require "ledge.ledge"
            ledge.set("redis_post", $TEST_NGINX_REDIS_PORT)
			rack.use(ledge)
			rack.run()
		';
        }
	location /__ledge {
		content_by_lua '
			ngx.say("this is a test content")
		';
    }
--- request
GET /test
--- error_code: 200


=== TEST 2: set-cookie headers: cache miss, cache-control & set-cookie in the header: the response should pass these values but not cache set-cookie (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
                        ngx.header["Set-Cookie"] = "test=PRIVATE_COOKIE_SHOULD_NOT_BE_CACHED; path=/; expires="..ngx.cookie_time(ngx.now() + 600) 
                        ngx.header["Cache-Control"] = "no-cache=\\"set-cookie\\""
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers_like
Cache-Control: no-cache="set-cookie"
Set-Cookie: test=PRIVATE_COOKIE_SHOULD_NOT_BE_CACHED; path=/; expires=[A-Za-z]{3}, \d{2}-[A-Za-z]{3}-\d{2} \d{2}:\d{2}:\d{2} GMT


=== TEST 3: set-cookie headers: cache hit (from TEST2): the cached header should not contain set-cookie (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache="set-cookie"
Set-Cookie: 


=== TEST 4: set-cookie headers: cache miss, set-cookie set but cache-control empty: the response should pass the set-cookie value and cache it (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"
                        
                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
			ngx.header["Set-Cookie"] = "test=SHARED_COOKIE_SHOULD_BE_CACHED; path=/; expires="..ngx.cookie_time(ngx.now() + 600)
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers_like
Cache-Control:
Set-Cookie: test=SHARED_COOKIE_SHOULD_BE_CACHED; path=/; expires=[A-Za-z]{3}, \d{2}-[A-Za-z]{3}-\d{2} \d{2}:\d{2}:\d{2} GMT


=== TEST 5: set-cookie headers: cache hit (from TEST 4): the cached header should contain the set-cookie value (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers_like
Cache-Control:
Set-Cookie: test=SHARED_COOKIE_SHOULD_BE_CACHED; path=/; expires=[A-Za-z]{3}, \d{2}-[A-Za-z]{3}-\d{2} \d{2}:\d{2}:\d{2} GMT 


=== TEST 6: set-cookie headers: cache miss, cache-control set but set-cookie empty: the response should pass the cache-control value and cache it (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
			ngx.header["Cache-Control"] = "no-cache=\\"set-cookie\\""
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache="set-cookie"
Set-Cookie:


=== TEST 7: set-cookie headers: cache hit (from TEST 6): the cached header should contain the cache-control value (issue #7)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache="set-cookie"
Set-Cookie:


=== TEST 8: Cache-Control case-sensitivity: Camel-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"
                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
                        ngx.header["Cache-Control"] = "no-cache"
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache


=== TEST 9: Cache-Control case-sensitivity: Camel-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location = /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 404


=== TEST 10: Cache-Control case-sensitivity: lower-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"
                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
                        ngx.header["cache-control"] = "no-cache"
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache


=== TEST 11: Cache-Control case-sensitivity: lower-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location = /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 404


=== TEST 12: Cache-Control case-sensitivity: upper-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location /test {
                content_by_lua '
                        local redis = require "resty.redis"
                        local red = redis:new()
                        red:connect("127.0.0.1", $TEST_NGINX_REDIS_PORT)
                        red:flushdb()
                        red:close()

                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"
                        rack.use(ledge)
                        rack.run()
                ';
        }
        location /__ledge {
                content_by_lua '
                        ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
                        ngx.header["CACHE-CONTROL"] = "no-cache"
                        ngx.say("this is a test content")
                ';
        }
--- request
GET /test
--- error_code: 200
--- response_headers
Cache-Control: no-cache


=== TEST 13: Cache-Control case-sensitivity: upper-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
        location = /test {
                content_by_lua '
                        local rack = require "resty.rack"
                        local ledge = require "ledge.ledge"

                        rack.use(ledge)
                        rack.run()
                ';
        }
--- request
GET /test
--- error_code: 404



