use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        rack = require 'resty.rack'
        ledge = require 'ledge.ledge'
        ledge.gset('redis_database', 1)
    ";
};

run_tests();

__DATA__
=== TEST 1: TTL from s-maxage (overrides max-age / Expires)
--- http_config eval: $::HttpConfig
--- config
	location /t {
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-TTL"] = res.ttl()
            end)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.header["Cache-Control"] = "max-age=600, s-maxage=1200"
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /t
--- response_headers
X-TTL: 1200


=== TEST 2: TTL from max-age (overrides Expires)
--- http_config eval: $::HttpConfig
--- config
	location /t {
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-TTL"] = res.ttl()
            end)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.header["Cache-Control"] = "max-age=600"
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /t
--- response_headers
X-TTL: 600


=== TEST 3: TTL from Expires
--- http_config eval: $::HttpConfig
--- config
	location /t {
        content_by_lua '
            ledge.bind("response_ready", function(req, res)
                res.header["X-TTL"] = res.ttl()
            end)
            rack.use(ledge)
            rack.run()
        ';
    }
    location /__ledge {
        content_by_lua '
            ngx.header["Expires"] = ngx.http_time(ngx.time() + 300)
            ngx.header["Cache-Control"] = "something"
            ngx.say("OK")
        ';
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /t
--- response_headers
X-TTL: 300
