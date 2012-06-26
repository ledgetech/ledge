use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 1;

my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";
};

$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

run_tests();


__DATA__
=== TEST 1: no event (issue #12)
--- http_config eval: $::HttpConfig
--- config
	location /test {
		content_by_lua '
			local rack = require "resty.rack"
			local ledge = require "ledge.ledge"

			local options = {
				proxy_location = "/test_content",

                                -- this block is to mitigate another issue
                                redis = {
                                        keepalive = {}
                                }

			}
			rack.use(ledge, options)
			rack.run()
		';
        }
	location /test_content {
		content_by_lua '
			ngx.say("this is a test content")
		';
        }
--- request
GET /test
--- error_code: 200

