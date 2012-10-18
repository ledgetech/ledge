use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 6;

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
my $pwd = cwd();

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        cjson = require 'cjson'
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ";
};

run_tests();

__DATA__
=== TEST 1: Test hop-by-hop headers are not cached.
--- http_config eval: $::HttpConfig
--- config
	location /hop_by_hop_headers {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        # We'll only test a couple of these as some of them alter
        # the response in a confusing (for the test) way.
        more_set_headers "Proxy-Authenticate foo";
        more_set_headers "Upgrade foo";
        echo "OK";
    }
--- request eval
["GET /hop_by_hop_headers","GET /hop_by_hop_headers"]
--- response_headers eval
["Proxy-Authenticate: foo\r\nUpgrade: foo","Proxy-Authenticate:\r\nUpgrade:"]
