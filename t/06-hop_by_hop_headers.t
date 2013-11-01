use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 6;

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
=== TEST 1: Test hop-by-hop headers are not passed on.
--- http_config eval: $::HttpConfig
--- config
	location /hop_by_hop_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /hop_by_hop_headers {
        more_set_headers "Cache-Control public, max-age=600";
        # We'll only test a couple of these as some of them alter
        # the response in a confusing (for the test) way.
        more_set_headers "Proxy-Authenticate foo";
        more_set_headers "Upgrade foo";
        echo "OK";
    }
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate: 
Upgrade: 


=== TEST 2: Test hop-by-hop headers were not cached.
--- http_config eval: $::HttpConfig
--- config
	location /hop_by_hop_headers_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate: 
Upgrade: 
