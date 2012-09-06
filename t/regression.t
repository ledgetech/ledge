use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 30;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua '
		rack = require "resty.rack"
		ledge = require "ledge.ledge"
		ledge.set("redis_database", $ENV{TEST_LEDGE_REDIS_DATABASE})
	';
};

run_tests();


__DATA__
=== TEST 1: no event, no header (issue #12, #13, #14)
--- http_config eval: $::HttpConfig
--- server_config eval: $::RedisFlush
--- config
	location /regression_1 {
		content_by_lua '
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
GET /regression_1
--- error_code: 200

=== TEST 2: set-cookie headers: cache miss, cache-control & set-cookie in the header: the response should pass these values but not cache set-cookie (issue #7)
--- http_config eval: $::HttpConfig
--- config
	location /regression_2 {
		content_by_lua '
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
--- request eval
["GET /regression_2","GET /regression_2"]
--- error_code eval
[200, 200]
--- response_body eval
["this is a test content\x{0a}", "this is a test content\x{0a}"]
--- response_headers_like eval
["Cache-Control: no-cache=\"set-cookie\"
Set-Cookie: test=PRIVATE_COOKIE_SHOULD_NOT_BE_CACHED; path=/; expires=[A-Za-z]{3}, \\d{2}-[A-Za-z]{3}-\\d{2} \\d{2}:\\d{2}:\\d{2} GMT",
"Cache-Control: no-cache=\"set-cookie\"
Set-Cookie:"]


=== TEST 3: set-cookie headers: cache miss, set-cookie set but cache-control empty: the response should pass the set-cookie value and cache it (issue #7)
--- http_config eval: $::HttpConfig
--- config
	location /regression_3 {
		content_by_lua '
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
--- request eval
["GET /regression_3","GET /regression_3"]
--- error_code eval
[200, 200]
--- response_headers_like eval
["Cache-Control:
Set-Cookie: test=SHARED_COOKIE_SHOULD_BE_CACHED; path=/; expires=[A-Za-z]{3}, \\d{2}-[A-Za-z]{3}-\\d{2} \\d{2}:\\d{2}:\\d{2} GMT",
"Cache-Control:
Set-Cookie: test=SHARED_COOKIE_SHOULD_BE_CACHED; path=/; expires=[A-Za-z]{3}, \\d{2}-[A-Za-z]{3}-\\d{2} \\d{2}:\\d{2}:\\d{2} GMT"] 


=== TEST 4: set-cookie headers: cache miss, cache-control set but set-cookie empty: the response should pass the cache-control value and cache it (issue #7)
--- http_config eval: $::HttpConfig
--- config
	location /regression_4 {
		content_by_lua '
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
--- request eval
["GET /regression_4", "GET /regression_4"]
--- error_code eval
[200, 200]
--- response_headers eval
["Cache-Control: no-cache=\"set-cookie\"
Set-Cookie:",
"Cache-Control: no-cache=\"set-cookie\"
Set-Cookie:"]


=== TEST 5: Cache-Control case-sensitivity: Camel-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
	location /regression_5 {
		content_by_lua '
			ledge.bind("origin_fetched", function(req, res)
				if req.accepts_cache() then
					res.header["X-Test"] = "Not Cacheable"
				end
			end)

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
GET /regression_5
--- error_code: 200
--- response_headers
Cache-Control: no-cache
X-Test: Not Cacheable


=== TEST 6: Cache-Control case-sensitivity: lower-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
	location /regression_6 {
		content_by_lua '
			ledge.bind("origin_fetched", function(req, res)
				if req.accepts_cache() then
					res.header["X-Test"] = "Not Cacheable"
				end
			end)

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
GET /regression_6
--- error_code: 200
--- response_headers
Cache-Control: no-cache
X-Test: Not Cacheable


=== TEST 7: Cache-Control case-sensitivity: upper-case (issue #6)
--- http_config eval: $::HttpConfig
--- config
	location /regression_7 {
		content_by_lua '
			ledge.bind("origin_fetched", function(req, res)
				if req.accepts_cache() then
					res.header["X-Test"] = "Not Cacheable"
				end
			end)

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
GET /regression_7
--- error_code: 200
--- response_headers
Cache-Control: no-cache
X-Test: Not Cacheable

