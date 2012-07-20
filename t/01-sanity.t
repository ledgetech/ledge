use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 4; 

my $pwd = cwd();

$ENV{TEST_NGINX_REDIS_DB} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		rack = require 'resty.rack'
		ledge = require 'ledge.ledge'
		ledge.gset('redis_database', $ENV{TEST_NGINX_REDIS_DB})
	";
};

run_tests();

__DATA__
=== TEST 1: Module loading
--- http_config eval: $::HttpConfig
--- config
	location /sanity_1 {
        echo "OK";
    }
--- request
GET /sanity_1
--- no_error_log
[error]


=== TEST 2A: Cache Miss - cache not available & non-cacheable content
--- http_config eval: $::HttpConfig
--- config
	location /sanity_2 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

	location /__ledge {
		content_by_lua '
			ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)
			ngx.header["Cache-Control"] = "no-cache"

			local req_header = ngx.req.get_headers()["X-Test-Var"]
			ngx.say("response to a request with header:"..req_header)
		';
	}

--- more_headers
X-Test-Var: sanity_2a 
--- request
GET /sanity_2
--- response_headers
Cache-Control: no-cache
--- response_body
response to a request with header:sanity_2a


=== TEST 2B: Cache Miss - cache still not available as TEST 2A handled a non-cacheable content
--- http_config eval: $::HttpConfig
--- config
	location =/sanity_2 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

--- request
GET /sanity_2
--- error_code: 404


=== TEST 3A: Cache Miss - cache not available & cacheable content
--- http_config eval: $::HttpConfig
--- config
	location /sanity_3 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

	location /__ledge {
		content_by_lua '
			ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)

			local req_header = ngx.req.get_headers()["X-Test-Var"]
			ngx.say("response to a request with header:"..req_header)
		';
	}

--- more_headers
X-Test-Var: sanity_3a
--- request
GET /sanity_3
--- response_headers
X-Cache: MISS
--- response_body
response to a request with header:sanity_3a


=== TEST 3B: Cache Hit - cache available & cacheable content
--- http_config eval: $::HttpConfig
--- config
	location /sanity_3 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

--- request
GET /sanity_3
--- response_headers
X-Cache: HIT
--- response_body
response to a request with header:sanity_3a


=== TEST 3C: Cache Miss - cache avaialble but request header prevents reading from cache
--- http_config eval: $::HttpConfig
--- config
	location /sanity_3 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

	location /__ledge {
		content_by_lua '
			ngx.header["Expires"] = ngx.http_time(ngx.now() + 600)

			local req_header = ngx.req.get_headers()["X-Test-Var"]
			ngx.say("response to a request with header:"..req_header)
		';
	}

--- more_headers
Cache-Control: no-cache 
X-Test-Var: sanity_3c
--- request
GET /sanity_3
--- response_headers
X-Cache: MISS
--- response_body
response to a request with header:sanity_3c


=== TEST 3D: Cache Hit - cache available but refreshed by the request at TEST 3C even if the requester avoided a cached content
--- http_config eval: $::HttpConfig
--- config
	location /sanity_3 {
		content_by_lua '
			rack.use(ledge)
			rack.run()
		';
	}

--- request
GET /sanity_3
--- response_headers
X-Cache: HIT
--- response_body
response to a request with header:sanity_3c
