use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 16;

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
=== TEST 1: GET
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /req_method_1 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
        ngx.say(ngx.req.get_method())
    ';
}
--- request
GET /req_method_1_prx
--- response_body
GET


=== TEST 2: HEAD gets GET request
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1


=== TEST 3: HEAD revalidate
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /req_method_1 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
HEAD /req_method_1_prx
--- response_headers
Etag: req_method_1


=== TEST 4: GET still has body
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1
--- response_body
GET


=== TEST 5: POST doesn't get cached copy
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /req_method_1 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_posted"
        ngx.say(ngx.req.get_method())
    ';
}
--- request
POST /req_method_1_prx
--- response_headers
Etag: req_method_posted
--- response_body
POST


=== TEST 6: GET uses cached POST response.
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_posted
--- response_body
POST


=== TEST 7: 501 on unrecognised method
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua '
        ledge:run()
    ';
}
--- request
FOOBAR /req_method_1
--- error_code: 501
