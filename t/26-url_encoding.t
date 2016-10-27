use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

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
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Spaces in URIs are encoded
--- http_config eval: $::HttpConfig
--- config
    location /uri_encoding_1_entry {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:connect("127.0.0.1", 1984)
            res, err = httpc:request({
                path = "/uri encoding_1_prx",
            })
            ngx.print(res:read_body())
        }
    }
	location "/uri encoding_1_prx" {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location "/uri encoding_1" {
        content_by_lua_block {
            ngx.say(ngx.var.request_uri)
        }
    }
--- request
GET /uri_encoding_1_entry
--- response_body
/uri%20encoding_1
--- no_error_log
[error]


=== TEST 2: Encoded CRLF in URIs have percentages encoded to avoid response splitting
--- http_config eval: $::HttpConfig
--- config
    location /entry_uri_encoding_2 {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:connect("127.0.0.1", 1984)
            res, err = httpc:request({
                path = "/prx_uri_encoding_2_%250d%250A",
            })
            ngx.print(res:read_body())
        }
    }
	location /prx_uri_encoding_2 {
        rewrite ^/prx_(.*)$ /$1 break;
        content_by_lua_block {
            ledge:run()
        }
    }
    location /uri_encoding_2 {
        content_by_lua_block {
            ngx.say(ngx.var.request_uri)
        }
    }
--- request
GET /entry_uri_encoding_2
--- response_body
/uri_encoding_2_%250D%250A
--- no_error_log
[error]
