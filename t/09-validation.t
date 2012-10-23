use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2); 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
	";
    if_modified_since off;
};

run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test1"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 100)
        ngx.say("TEST 1")
    ';
}
--- request
GET /validation
--- response_body
TEST 1


=== TEST 2: Unspecified end-to-end revalidation (max-age=0 + no validator)
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test2"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 90)
        ngx.say("TEST 2")
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation
--- response_body
TEST 2


=== TEST 3: Revalidate against cache using IMS in the future.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 100))
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test3"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 80)
        ngx.say("TEST 3")
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation
--- error_code: 304
--- response_body


=== TEST 4: Revalidate against cache using Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test4"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 100)
        ngx.say("TEST 4")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation
--- error_code: 304
--- response_body


=== TEST 4b: Revalidate against cache using LM and Etag.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 100))
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test4"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 100)
        ngx.say("TEST 4")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation
--- error_code: 304
--- response_body


=== TEST 5: Specific end-to-end revalidation using IMS, upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() - 150))
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation
--- error_code: 200
--- response_body
TEST 2


=== TEST 6: Specific end-to-end revalidation using INM, upstream 304.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test6
--- request
GET /validation
--- error_code: 200
--- response_body
TEST 2


=== TEST 7: Specific end-to-end revalidation using IMS, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() - 150))
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test7"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 70)
        ngx.say("TEST 7")
    ';
}
--- more_headers
Cache-Control: max-age=0
--- request
GET /validation
--- error_code: 200
--- response_body
TEST 7


=== TEST 8: Specific end-to-end revalidation using INM, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "test8"
        ngx.header["Last-Modified"] = ngx.http_time(ngx.time() - 60)
        ngx.say("TEST 8")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: test2
--- request
GET /validation
--- error_code: 200
--- response_body
TEST 8


=== TEST 9: Check revalidation re-saved.
--- http_config eval: $::HttpConfig
--- config
location /validation {
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /validation
--- error_code: 200
--- response_body
TEST 8
