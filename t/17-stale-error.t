use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 20;

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;
my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ";
};


run_tests();

__DATA__
=== TEST 1: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /error {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /error
--- response_body
OK


=== TEST 1a: Serve from cache on error
--- http_config eval: $::HttpConfig
--- config
    location /error {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /error
--- response_body
OK


=== TEST 1b: Serve from cache on error with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error {
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /error
--- response_body
OK


=== Test 2: Prime Cache with expired content
--- http_config eval: $::HttpConfig
--- config
    location /error2 {
        content_by_lua '
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                res.header["Cache-Control"] = "max-age=0"
            end)        
            ledge:run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK2";
    }
--- request
GET /error2
--- response_body
OK2


=== Test 2a: Serve from cache on error with stale warning
--- http_config eval: $::HttpConfig
--- config
    location /error {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /error2
--- response_headers_like
Warning: 110 .*
--- response_body
OK2

=== Test 2b: Pass through error if outside stale window
--- http_config eval: $::HttpConfig
--- config
    location /error2 {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /error2
--- error_code: 500

=== Test 2c: Serve from cache on error with stale warning with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error {
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /error2
--- response_headers_like
Warning: 110 .*
--- response_body
OK2

=== Test 2d: Pass through error if outside stale window with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error2 {
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /error2
--- error_code: 500

=== TEST 3: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /error3 {
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /error3
--- response_body
OK


=== TEST 3a: stale_if_error config should override headers
--- http_config eval: $::HttpConfig
--- config
    location /error3 {
        content_by_lua '
            ledge:config_set("stale_if_error", 99999)
            ledge:run()
        ';
    }
    location /__ledge_origin {
        return 500;
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /error3
--- response_body
OK

