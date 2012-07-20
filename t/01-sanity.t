use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 2;

my $pwd = cwd();

$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        rack = require 'resty.rack'
        ledge = require 'ledge.ledge'
    ";
};

run_tests();

__DATA__
=== TEST 1: Module loading
--- http_config eval: $::HttpConfig
--- config
	location /t {
        echo "OK";
    }
--- request
GET /t
--- no_error_log
[error]
