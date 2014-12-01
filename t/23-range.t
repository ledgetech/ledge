use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 6;

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
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

run_tests();

__DATA__
=== TEST 1: Cache MISS, pass range upstream. Whole entitiy will be revalidated in the background.
--- http_config eval: $::HttpConfig
--- config
    location /range_entry {
        echo_location /range_prx;
        echo_flush;
        echo_sleep 2;
    }
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /range {
        content_by_lua '
            ngx.header["Cache-Control"] = "public, max-age=3600";
            if ngx.req.get_headers()["Range"] then
                ngx.status = 206
                ngx.print("01")
            else
                ngx.status = 200
                ngx.print("0123456789");
            end
        ';
    }
--- more_headers
Range: bytes=0-1
--- request
GET /range_entry
--- response_body: 01
--- timeout: 6


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
Content-Range: bytes 0-1/10
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
Content-Range: bytes 3-5/10
Cache-Control: public, max-age=3600
--- response_body: 345
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
Content-Range: bytes 6-9/10
Cache-Control: public, max-age=3600
--- response_body: 6789
--- error_code: 206


=== TEST 5: Cache HIT, get offset from end bytes. 
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
Content-Range: bytes 6-9/10
Cache-Control: public, max-age=3600
--- response_body: 6789
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
Content-Range: bytes 0-5/10
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
Content-Range: bytes 3-7/10
Cache-Control: public, max-age=3600
--- response_body: 34567
--- error_code: 206


=== TEST 8: Ask for range outside content length, last byte should be reduced to length.
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=3-12
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Content-Range: bytes 3-9/10
Cache-Control: public, max-age=3600
--- response_body: 3456789
--- error_code: 206


=== TEST 9: Range end is smaller than range start (unsatisfiable)
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=12-3
--- request
GET /range_prx
--- response_headers
Content-Range: bytes */10
--- response_body:
--- error_code: 416


=== TEST 9b: Range end offset is larger than range (unsatisfiable)
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=-12
--- request
GET /range_prx
--- response_headers
Content-Range: bytes */10
--- response_body:
--- error_code: 416


=== TEST 10: Range is incompreshensible
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=asdfa
--- request
GET /range_prx
--- response_headers
Content-Range: bytes */10
--- response_body:
--- error_code: 416


=== TEST 10b: Range is incompreshensible
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: isdfsdbytes=asdfa
--- request
GET /range_prx
--- response_headers
Content-Range: bytes */10
--- response_body:
--- error_code: 416


=== TEST 11: Multi byte ranges
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=0-3,5-8
--- request
GET /range_prx
--- no_error_log
[error]
--- response_body_like chop

--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 0-3/10

0123
--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 5-8/10

5678
--[0-9a-z]+--
--- error_code: 206


=== TEST 12a: Prime cache with buffers smaller than range.
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("buffer_size", 3)
            ledge:run()
        ';
    }

    location /range_12 {
        content_by_lua '
            ngx.header["Cache-Control"] = "public, max-age=3600";
            ngx.status = 200
            ngx.print("0123456789");
        ';
    }
--- request
GET /range_12_prx
--- response_body: 0123456789


=== TEST 12b: Multi byte ranges across chunk boundaries
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=0-3,5-8
--- request
GET /range_12_prx
--- no_error_log
[error]
--- response_body_like chop

--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 0-3/10

0123
--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 5-8/10

5678
--[0-9a-z]+--
--- error_code: 206


=== TEST 12c: Single range which spans chunk boundaries
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=4-7
--- request
GET /range_12_prx
--- response_headers
Content-Range: bytes 4-7/10
--- response_body: 4567
--- error_code: 206


=== TEST 12d: Multi byte reversed ranges. Return in sane order.
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=5-8,0-3
--- request
GET /range_12_prx
--- no_error_log
[error]
--- response_body_like chop

--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 0-3/10

0123
--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 5-8/10

5678
--[0-9a-z]+--
--- error_code: 206


=== TEST 12d: Multi byte reversed overlapping ranges. Return in sane order and coalesced.
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=5-8,0-3,4-6
--- request
GET /range_12_prx
--- no_error_log
[error]
--- response_body_like chop

--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 0-3/10

0123
--[0-9a-z]+
Content-Type: text/plain
Content-Range: bytes 4-8/10

45678
--[0-9a-z]+--
--- error_code: 206


=== TEST 12d: Multi byte reversed overlapping ranges. Return in sane order and coalesced to single range.
--- http_config eval: $::HttpConfig
--- config
    location /range_12_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=5-8,0-3,3-6
--- request
GET /range_12_prx
--- response_headers
Content-Range: bytes 0-8/10
--- response_body: 012345678
--- error_code: 206
--- no_error_log
[error]
