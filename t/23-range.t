use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) - 5;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests.
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /range {
        content_by_lua '
            ngx.header["Cache-Control"] = "public, max-age=3600";
            ngx.print("0123456789");
        ';
    }
--- request
GET /range_prx
--- response_body: 0123456789


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 5b: Cache HIT, get byte to end
--- http_config eval: $::HttpConfig
--- config
    location /range_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=2-
--- request
GET /range_prx
--- response_headers_like
X-Cache: HIT from .*
--- response_headers
Content-Range: bytes 2-9/10
Cache-Control: public, max-age=3600
--- response_body: 23456789
--- error_code: 206
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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


=== TEST 13a: Prime with ESI content, thus of interderminate length.
--- http_config eval: $::HttpConfig
--- config
    location /range_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }

    location /range_13 {
        default_type text/html;
        content_by_lua '
            ngx.header["Cache-Control"] = "public, max-age=3600";
            ngx.header["Surrogate-Control"] = "content=\\\"ESI/1.0\\\""
            ngx.status = 200
            ngx.print("01");
            ngx.print("<esi:vars>$(QUERY_STRING{a})</esi:vars>")
            ngx.print("56789");
        ';
    }
--- request
GET /range_13_prx?a=234
--- response_body: 0123456789
--- no_error_log
[error]


=== TEST 13b: Normal range over indeterminate length (must 200 with full reply)
--- http_config eval: $::HttpConfig
--- config
    location /range_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=0-5
--- request
GET /range_13_prx?a=234
--- response_body: 0123456789
--- error_code: 200
--- no_error_log
[error]


=== TEST 13c: Offset to end over indeterminate length (must 200 with full reply)
--- http_config eval: $::HttpConfig
--- config
    location /range_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=-5
--- request
GET /range_13_prx?a=234
--- response_body: 0123456789
--- error_code: 200
--- no_error_log
[error]


=== TEST 13c: Range to end over indeterminate length (must 200 with full reply)
--- http_config eval: $::HttpConfig
--- config
    location /range_13_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }
--- more_headers
Range: bytes=5-
--- request
GET /range_13_prx?a=234
--- response_body: 0123456789
--- error_code: 200
--- no_error_log
[error]
