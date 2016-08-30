use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) + 1;

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
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /error_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 1a: Serve from cache on error
--- http_config eval: $::HttpConfig
--- config
    location /error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /error_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 1b: Serve from cache on error with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /error {
        return 500;
    }
--- more_headers
Cache-Control: no-cache, stale-if-error=9999
--- request
GET /error_prx
--- response_body
OK
--- no_error_log
[error]


=== Test 2: Prime Cache with expired content
--- http_config eval: $::HttpConfig
--- config
    location /error2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                res.header["Cache-Control"] = "max-age=0"
            end)
            ledge:run()
        ';
    }
    location /error2 {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK2";
    }
--- request
GET /error2_prx
--- response_body
OK2
--- no_error_log
[error]


=== Test 2a: Serve from cache on error with stale warning
--- http_config eval: $::HttpConfig
--- config
    location /error2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /error2_prx
--- response_headers_like
Warning: 110 .*
--- response_body
OK2
--- no_error_log
[error]


=== Test 2b: Pass through error if outside stale window
--- http_config eval: $::HttpConfig
--- config
    location /error2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /error2_prx
--- error_code: 500
--- no_error_log
[error]


=== Test 2c: Serve from cache on error with stale warning with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /error2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /error2_prx
--- response_headers_like
Warning: 110 .*
--- response_body
OK2
--- no_error_log
[error]


=== Test 2d: Pass through error if outside stale window with collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /error2_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /error2 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=0
--- request
GET /error2_prx
--- error_code: 500
--- no_error_log
[error]


=== TEST 3: Prime Cache
--- http_config eval: $::HttpConfig
--- config
    location /error3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error3 {
        more_set_headers "Cache-Control public, max-age=600";
        echo "OK";
    }
--- request
GET /error3_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 3a: stale_if_error config should override headers
--- http_config eval: $::HttpConfig
--- config
    location /error3_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("stale_if_error", 99999)
            ledge:run()
        ';
    }
    location /error3 {
        return 500;
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /error3_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 4: Prime gzipped response
--- http_config eval: $::HttpConfig
--- config
    location /error_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                --res.header["Cache-Control"] = "max-age=0"
            end)
            ledge:run()
        ';
    }
    location /error_4 {
        gzip on;
        gzip_proxied any;
        gzip_min_length 1;
        gzip_http_version 1.0;
        default_type text/html;
        more_set_headers  "Cache-Control: public, max-age=600";
        more_set_headers  "Content-Type: text/html";
        echo "OK";
    }
--- request
GET /error_4_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- no_error_log
[error]
--- wait: 1


=== Test 4b: Serve uncompressed from cache, with a disconnected warning (as content is not yet stale)
--- http_config eval: $::HttpConfig
--- config
    location /error_4_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /error_4 {
        return 500;
    }
--- more_headers
Cache-Control: stale-if-error=9999, max-age=0
--- request
GET /error_4_prx
--- response_headers_like
Warning: 112 .*
--- response_body
OK
--- no_error_log
[error]
