use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 3; 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
	init_by_lua "
		ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
		ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('enable_esi', true)
	";
};

run_tests();

__DATA__
=== TEST 1: Single line comments removed
--- http_config eval: $::HttpConfig
--- config
location /esi_1 {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.print("<!--esiCOMMENTED-->")
    ';
}
--- request
GET /esi_1
--- response_body: COMMENTED
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  


=== TEST 2: Multi line comments removed
--- http_config eval: $::HttpConfig
--- config
location /esi_2 {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.print("<!--esi")
        ngx.print("1")
        ngx.say("-->")
        ngx.say("2")
        ngx.say("<!--esi")
        ngx.say("3")
        ngx.print("-->")
    ';
}
--- request
GET /esi_2
--- response_body
1
2

3
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  


=== TEST 3: Single line <esi:remove> removed.
--- http_config eval: $::HttpConfig
--- config
location /esi_3 {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.print("<esi:remove>REMOVED</esi:remove>")
    ';
}
--- request
GET /esi_3
--- response_body
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  

=== TEST 4: Multi line <esi:remove> removed.
--- http_config eval: $::HttpConfig
--- config
location /esi_4 {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("1")
        ngx.say("<esi:remove>")
        ngx.say("2")
        ngx.say("</esi:remove>")
        ngx.say("3")
    ';
}
--- request
GET /esi_4
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  
--- response_body
1

3


=== TEST 5: Include fragment
--- http_config eval: $::HttpConfig
--- config
location /esi_5 {
    content_by_lua '
        ledge:run()
    ';
}
location /fragment_1 {
    echo "FRAGMENT";
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_1\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_5
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  
--- response_body
1
FRAGMENT
2


=== TEST 6: Include multiple fragments, in correct order.
--- http_config eval: $::HttpConfig
--- config
location /esi_6 {
    content_by_lua '
        ledge:run()
    ';
}
location /fragment_1 {
    content_by_lua '
        ngx.print("FRAGMENT_1")
    ';
}
location /fragment_2 {
    content_by_lua '
        ngx.print("FRAGMENT_2")
    ';
}
location /fragment_3 {
    content_by_lua '
        ngx.print("FRAGMENT_3")
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment_3\\" />")
        ngx.say("<esi:include src=\\"/fragment_1\\" />")
        ngx.say("<esi:include src=\\"/fragment_2\\" />")
    ';
}
--- request
GET /esi_6
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  
--- response_body
FRAGMENT_3
FRAGMENT_1
FRAGMENT_2


=== TEST 7: Leave instructions intact if ESI is not enabled.
--- http_config eval: $::HttpConfig
--- config
location /esi_7 {
    content_by_lua '
        ledge:config_set("enable_esi", false)
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.print("<!--esiCOMMENTED-->")
    ';
}
--- request
GET /esi_7
--- response_body: <!--esiCOMMENTED-->


=== TEST 8: Response cacheability is as short/new as the shortest/newest fragment.
--- http_config eval: $::HttpConfig
--- config
location /esi_8 {
    content_by_lua '
        ledge:run()
    ';
}
location /fragment_1 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.header["Last-Modified"] = "Fri, 23 Nov 2012 00:00:00 GMT"
        ngx.say("FRAGMENT_1")
    ';
}
location /fragment_2 {
    content_by_lua '
        ngx.header["Expires"] = ngx.http_time(ngx.time() + 30)
        ngx.say("FRAGMENT_2")
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Last-Modified"] = "Fri, 21 Nov 2012 00:00:00 GMT"
        ngx.say("<esi:include src=\\"/fragment_1\\" />")
        ngx.say("<esi:include src=\\"/fragment_2\\" />")
    ';
}
--- request
GET /esi_8
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  
Cache-Control: max-age=30
Last-Modified: Fri, 23 Nov 2012 00:00:00 GMT


=== TEST 9: Variable evaluation
--- http_config eval: $::HttpConfig
--- config
location /esi_9 {
    content_by_lua 'ledge:run()';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
        ngx.say("<esi:include src=\\"/fragment1?$(QUERY_STRING)\\" />")
        ngx.say("<esi:vars>$(QUERY_STRING)")
        ngx.say("$(QUERY_STRING)")
        ngx.say("</esi:vars>")
        ngx.say("$(QUERY_STRING)")
    ';
}
location /fragment1 {
    content_by_lua '
        ngx.say("FRAGMENT:"..ngx.var.args)
    ';
}
--- request
GET /esi_9?t=1
--- response_body
t=1
FRAGMENT:t=1

t=1
t=1

$(QUERY_STRING)


=== TEST 9b: Multiple Variable evaluation
--- http_config eval: $::HttpConfig
--- config
location /esi_9b {
    content_by_lua 'ledge:run()';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment1b?$(QUERY_STRING)&test=$(HTTP_x_esi_test)\\" />")
    ';
}
location /fragment1b {
    content_by_lua '
        ngx.print("FRAGMENT:"..ngx.var.args)
    ';
}
--- request
GET /esi_9b?t=1
--- more_headers
X-ESI-Test: foobar
--- response_body
FRAGMENT:t=1&test=foobar


=== TEST 10: Prime ESI in cache.
--- http_config eval: $::HttpConfig
--- config
location /esi_10 {
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_10?t=1
--- response_body
t=1
--- response_headers_like
X-Cache: MISS from .*


=== TEST 10b: ESI still runs on cache HIT.
--- http_config eval: $::HttpConfig
--- config
location /esi_10 {
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        ledge:run()
    ';
}
--- request
GET /esi_10?t=2
--- response_body
t=2
--- response_headers_like
X-Cache: HIT from .*


=== TEST 10c: ESI still runs on cache revalidation, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /esi_10 {
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10c"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: esi10
--- request
GET /esi_10?t=3
--- response_body
t=3
--- response_headers_like
X-Cache: MISS from .*


=== TEST 10d: ESI still runs on cache revalidation, upstream 200, locally valid.
--- http_config eval: $::HttpConfig
--- config
location /esi_10 {
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10c"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: esi10c
--- request
GET /esi_10?t=4
--- response_body
t=4
--- response_headers_like
X-Cache: MISS from .*


=== TEST 10e: ESI still runs on cache revalidation, upstream 304, locally valid.
--- http_config eval: $::HttpConfig
--- config
location /esi_10 {
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
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
If-None-Match: esi10
--- request
GET /esi_10?t=5
--- response_body
t=5
--- response_headers_like
X-Cache: MISS from .*


=== TEST 11a: Prime fragment
--- http_config eval: $::HttpConfig
--- config
location /fragment {
    content_by_lua '
        ledge:run()
    ';
}
location /__ledge_origin {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("FRAGMENT")
    ';
}
--- request
GET /fragment
--- response_body
FRAGMENT
--- error_code: 200

=== TEST 11b: Include fragment with client validators.
--- http_config eval: $::HttpConfig
--- config
location /esi_11 {
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 150))
        ledge:run()
    ';
}
location /fragment {
    content_by_lua 'ledge:run()';
}
location /__ledge_origin {
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_11
--- response_headers_like 
Warning: ^214 .* "Transformation applied"$  
--- response_body
1
FRAGMENT
2
