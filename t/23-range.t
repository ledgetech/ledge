use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/../lua-resty-redis/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ";
};

run_tests();

__DATA__
=== TEST 1: Cache MISS, upstream ignores range
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /range {
        more_set_headers "Cache-Control: public, max-age=3600";
        echo "0123456789";
    }
--- more_headers
Range: bytes=0-1
--- request
GET /range_prx
--- response_headers_like
X-Cache: MISS from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
0123456789


=== TEST 2: Cache HIT, get the first byte only
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=0-1
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body: 01
--- error_code: 206


=== TEST 3: Cache HIT, get middle bytes
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=3-5
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body: 2345
--- error_code: 206


=== TEST 4: Cache HIT, get middle to end bytes
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=6-
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
56789
--- error_code: 206

=== TEST 5: Cache HIT, get offset from end bytes. Log error as not supported.
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=-4
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body
6789
--- error_code: 206


=== TEST 6: Cache HIT, get beginning bytes spanning buffer size
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("buffer_size", 2)
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=0-5
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body: 012345
--- error_code: 206


=== TEST 7: Cache HIT, get middle bytes spanning buffer size
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("buffer_size", 4)
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=3-7
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Cache-Control: public, max-age=3600
--- response_body: 234567
--- error_code: 206
