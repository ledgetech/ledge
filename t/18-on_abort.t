use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 2;

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
        --ledge:run_workers()
    ";
        
    lua_check_client_abort on;

    upstream test-upstream {
        server 127.0.0.1:1984;
        keepalive 16;
    }
};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Warning when unable to set client abort handler
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        lua_check_client_abort off;
        content_by_lua '
            ledge:run()
        ';
    }
    location /abort {
        echo 'foo';
    }
--- request
GET /abort_prx
--- error_log
on_abort handler not set


=== TEST 2a: Client abort mid save should still save to cache (run and abort)
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /abort {
        content_by_lua '
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.flush(true)
            ngx.sleep(2)
            ngx.say("FINISH")
       ';
    }
--- request
GET /abort_prx
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 2b: Prove we have a complete cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]


=== TEST 3a: Client abort before save aborts fetching
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /abort {
        content_by_lua '
            ngx.sleep(2)
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START 2")
            ngx.say("FINISH 2")
       ';
    }
--- request
GET /abort_prx
--- more_headers
Cache-Control: max-age=0
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 3b: Prove we still have the previous cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]


=== TEST 4a: Prime immediately expiring cache item
--- http_config eval: $::HttpConfig
--- config
location /abort_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    ';
}
location /abort {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    ';
}
--- more_headers
Cache-Control: no-cache
--- request
GET /abort_prx
--- response_body
OK
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Client abort before fetch with collapsed forwarding on cancels abort
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:bind("origin_required", function(res)
                ngx.sleep(2)
            end)
            ledge:run()
        ';
    }
    location /abort {
        content_by_lua '
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.say("FINISH")
       ';
    }
--- request
GET /abort_prx
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 4c: Prove we have the previous cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]

=== TEST 5: No error when keepalive_requests exceeded
--- http_config eval: $::HttpConfig
--- config
    location = /abort_top {
        content_by_lua '
            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:request_uri("http://"..ngx.var.server_addr..":"..ngx.var.server_port.."/abort_ngx")
            if not res then
                ngx.log(ngx.ERR, err)
            end
            local res, err = httpc:request_uri("http://"..ngx.var.server_addr..":"..ngx.var.server_port.."/abort_ngx")
            if not res then
                ngx.log(ngx.ERR, err)
            end
            ngx.say("OK")
        ';
    }
    location = /abort_ngx {
        rewrite ^ /abort_prx break;
        proxy_pass http://test-upstream;
    }
    location = /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        keepalive_requests 1;
        content_by_lua '
            ledge:run()
        ';
    }
    location = /abort {
        content_by_lua '
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.say("FINISH")
       ';
    }
--- request
GET /abort_top
--- response_body
OK
--- error_code: 200
--- no_error_log
[error]
