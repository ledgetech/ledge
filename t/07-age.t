use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 4;

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: No calculated Age header on cache MISS.
--- http_config eval: $::HttpConfig
--- config
	location /age_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /age {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /age_prx
--- response_headers
Age:


=== TEST 2: Age header on cache HIT
--- http_config eval: $::HttpConfig
--- config
	location /age_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /age {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /age_prx
--- response_headers_like
Age: \d+
