use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests =>  repeat_each() * (blocks() * 3) + 5; 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
    resolver 8.8.8.8;
    if_modified_since off;
    lua_package_path "$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
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
        ledge:config_set('esi_enabled', true)

        function run()
            ledge:bind('origin_fetched', function(res)
                res.header['Surrogate-Control'] = [[content=\\"ESI/1.0\\"]]
            end)
            ledge:run()
        end
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

master_on();
no_long_string();
run_tests();

__DATA__
=== TEST 1: Single line comments removed
--- http_config eval: $::HttpConfig
--- config
location /esi_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_1 {
    default_type text/html;
    content_by_lua '
        ngx.print("<!--esiCOMMENTED-->")
    ';
}
--- request
GET /esi_1_prx
--- response_body: COMMENTED
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 1b: Single line comments removed, esi instructions remain
--- http_config eval: $::HttpConfig
--- config
location /esi_1b_prx {
    rewrite ^(.*)_prx$ $1b break;
    content_by_lua '
        run()
    ';
}
location /esi_1b {
    default_type text/html;
    content_by_lua '
        ngx.print("<!--esi<esi:vars>$(QUERY_STRING)</esi:vars>-->")
    ';
}
--- request
GET /esi_1b_prx?a=1b
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 2: Multi line comments removed
--- http_config eval: $::HttpConfig
--- config
location /esi_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_2 {
    default_type text/html;
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
GET /esi_2_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
2

3


=== TEST 2b: Multi line comments removed, ESI instructions still intact
--- http_config eval: $::HttpConfig
--- config
location /esi_2_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_2 {
    default_type text/html;
    content_by_lua '
        ngx.print("<!--esi")
        ngx.print([[1234 <esi:include src="/test" />]])
        ngx.say("-->")
        ngx.say("2345")
        ngx.say("<!--esi")
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
        ngx.print("-->")
    ';
}
--- request
GET /esi_2_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1234 <esi:include src="/test" />
2345

<esi:vars>$(QUERY_STRING)</esi:vars>


=== TEST 3: Single line <esi:remove> removed.
--- http_config eval: $::HttpConfig
--- config
location /esi_3_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_3 {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:remove>REMOVED</esi:remove>")
    ';
}
--- request
GET /esi_3_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body


=== TEST 4: Multi line <esi:remove> removed.
--- http_config eval: $::HttpConfig
--- config
location /esi_4_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_4 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.say("<esi:remove>")
        ngx.say("2")
        ngx.say("</esi:remove>")
        ngx.say("3")
    ';
}
--- request
GET /esi_4_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1

3


=== TEST 5: Include fragment
--- http_config eval: $::HttpConfig
--- config
location /esi_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment_1 {
    echo "FRAGMENT";
}
location /esi_5 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_1\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_5_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
FRAGMENT
2



=== TEST 6: Include multiple fragments, in correct order.
--- http_config eval: $::HttpConfig
--- config
location /esi_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
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
location /esi_6 {
    default_type text/html;
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment_3\\" />")
        ngx.say("MID LINE <esi:include src=\\"/fragment_1\\" />")
        ngx.say("<esi:include src=\\"/fragment_2\\" />")
    ';
}
--- request
GET /esi_6_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
FRAGMENT_3
MID LINE FRAGMENT_1
FRAGMENT_2


=== TEST 7: Leave instructions intact if ESI is not enabled.
--- http_config eval: $::HttpConfig
--- config
location /esi_7_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_enabled", false)
        run()
    ';
}
location /esi_7 {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_7_prx?a=1
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>


=== TEST 7b: Leave instructions intact if ESI delegation is enabled - slow path.
--- http_config eval: $::HttpConfig
--- config
location /esi_7b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_allow_surrogate_delegation", true)
        run()
    ';
}
location /esi_7b {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_7b_prx?a=1
--- more_headers
Surrogate-Capability: localhost="ESI/1.0"
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"


=== TEST 7c: Leave instructions intact if ESI delegation is enabled - fast path.
--- http_config eval: $::HttpConfig
--- config
location /esi_7b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_allow_surrogate_delegation", true)
        run()
    ';
}
--- request
GET /esi_7b_prx?a=1
--- more_headers
Surrogate-Capability: localhost="ESI/1.0"
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"


=== TEST 7d: Leave instructions intact if ESI delegation is enabled by IP, slow path.
--- http_config eval: $::HttpConfig
--- config
location /esi_7d_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_allow_surrogate_delegation", {"127.0.0.1"} )
        run()
    ';
}
location /esi_7d {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_7d_prx?a=1
--- more_headers
Surrogate-Capability: localhost="ESI/1.0"
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"


=== TEST 7e: Leave instructions intact if ESI delegation is enabled by IP, fast path.
--- http_config eval: $::HttpConfig
--- config
location /esi_7d_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_allow_surrogate_delegation", {"127.0.0.1"} )
        run()
    ';
}
--- request
GET /esi_7d_prx?a=1
--- more_headers
Surrogate-Capability: localhost="ESI/1.0"
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"


=== TEST 8: Response downstrean cacheability is zero'd when ESI processing has occured.
--- http_config eval: $::HttpConfig
--- config
location /esi_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment_1 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("FRAGMENT_1")
    ';
}
location /esi_8 {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("<esi:include src=\\"/fragment_1\\" />")
    ';
}
--- request
GET /esi_8_prx
--- response_headers_like 
Cache-Control: private, must-revalidate
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 9: Variable evaluation
--- http_config eval: $::HttpConfig
--- config
location /esi_9_prx {
    rewrite ^(.*)_prx(.*)$ $1 break;
    content_by_lua 'run()';
}
location /esi_9 {
    default_type text/html;
    content_by_lua '
        ngx.say("HTTP_COOKIE: <esi:vars>$(HTTP_COOKIE)</esi:vars>");
        ngx.say("HTTP_COOKIE{SQ_SYSTEM_SESSION}: <esi:vars>$(HTTP_COOKIE{SQ_SYSTEM_SESSION})</esi:vars>");
        ngx.say("<esi:vars>");
        ngx.say("HTTP_COOKIE: $(HTTP_COOKIE)");
        ngx.say("HTTP_COOKIE{SQ_SYSTEM_SESSION}: $(HTTP_COOKIE{SQ_SYSTEM_SESSION})");
        ngx.print("</esi:vars>");
    ';
}
--- more_headers
Cookie: myvar=foo; SQ_SYSTEM_SESSION=hello
--- request
GET /esi_9_prx?t=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
HTTP_COOKIE: myvar=foo; SQ_SYSTEM_SESSION=hello
HTTP_COOKIE{SQ_SYSTEM_SESSION}: hello

HTTP_COOKIE: myvar=foo; SQ_SYSTEM_SESSION=hello
HTTP_COOKIE{SQ_SYSTEM_SESSION}: hello


=== TEST 9b: Multiple Variable evaluation
--- http_config eval: $::HttpConfig
--- config
location /esi_9b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_9b {
    default_type text/html;
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment1b?$(QUERY_STRING)&test=$(HTTP_X_ESI_TEST)\\" />")
    ';
}
location /fragment1b {
    content_by_lua '
        ngx.print("FRAGMENT:"..ngx.var.args)
    ';
}
--- request
GET /esi_9b_prx?t=1
--- more_headers
X-ESI-Test: foobar
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
FRAGMENT:t=1&test=foobar



=== TEST 9c: Dictionary variable syntax (cookie)
--- http_config eval: $::HttpConfig
--- config
location /esi_9c_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_9c {
    default_type text/html;
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment1c?$(QUERY_STRING{t})&test=$(HTTP_COOKIE{foo})\\" />")
    ';
}
location /fragment1c {
    content_by_lua '
        ngx.print("FRAGMENT:"..ngx.var.args)
    ';
}
--- request
GET /esi_9c_prx?t=1
--- more_headers
Cookie: foo=bar
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
FRAGMENT:1&test=bar


=== TEST 9d: List variable syntax (accept-language)
--- http_config eval: $::HttpConfig
--- config
location /esi_9d_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_9d {
    default_type text/html;
    content_by_lua '
        ngx.say("<esi:include src=\\"/fragment1d?$(QUERY_STRING{t})&en-gb=$(HTTP_ACCEPT_LANGUAGE{en-gb})&de=$(HTTP_ACCEPT_LANGUAGE{de})\\" />")
    ';
}
location /fragment1d {
    content_by_lua '
        ngx.print("FRAGMENT:"..ngx.var.args)
    ';
}
--- request
GET /esi_9d_prx?t=1
--- more_headers
Accept-Language: da, en-gb, fr 
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
FRAGMENT:1&en-gb=true&de=false


=== TEST 9e: Default variable values
--- http_config eval: $::HttpConfig
--- config
location /esi_9e_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_9e {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:vars>")
        ngx.say("$(QUERY_STRING{a}|novalue)")
        ngx.say("$(QUERY_STRING{b}|novalue)")
        ngx.say("$(QUERY_STRING{c}|\'quoted values can have spaces\')")
        ngx.say("$(QUERY_STRING{d}|unquoted values must not have spaces)")
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_9e_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
novalue
quoted values can have spaces
$(QUERY_STRING{d}|unquoted values must not have spaces)


=== TEST 9f: Custom variable injection
--- http_config eval: $::HttpConfig
--- config
location /esi_9f_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.ctx.ledge_esi_custom_variables = {
            ["CUSTOM_DICTIONARY"] = { a = 1, b = 2},
            ["CUSTOM_STRING"] = "foo"
        }

        run()    
    ';
}
location /esi_9f {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:vars>")
        ngx.say("$(CUSTOM_DICTIONARY|novalue)")
        ngx.say("$(CUSTOM_DICTIONARY{a})")
        ngx.say("$(CUSTOM_DICTIONARY{b})")
        ngx.say("$(CUSTOM_STRING)")
        ngx.say("$(CUSTOM_STRING{x}|novalue)")
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_9f_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
novalue
1
2
foo
novalue


=== TEST 10: Prime ESI in cache.
--- http_config eval: $::HttpConfig
--- config
location /esi_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        run()
    ';
}
location /esi_10 {
    default_type text/html;
    content_by_lua '
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_10_prx?t=1
--- response_body
t=1
--- error_code: 404
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


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
        run()
    ';
}
--- request
GET /esi_10?t=2
--- response_body
t=2
--- error_code: 404
--- response_headers_like
X-Cache: HIT from .*
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 10c: ESI still runs on cache revalidation, upstream 200.
--- http_config eval: $::HttpConfig
--- config
location /esi_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        run()
    ';
}
location /esi_10 {
    default_type text/html;
    content_by_lua '
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10c"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: esi10
--- request
GET /esi_10_prx?t=3
--- response_body
t=3
--- error_code: 404
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 10d: ESI still runs on cache revalidation, upstream 200, locally valid.
--- http_config eval: $::HttpConfig
--- config
location /esi_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        run()
    ';
}
location /esi_10 {
    default_type text/html;
    content_by_lua '
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "esi10d"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: esi10c
--- request
GET /esi_10_prx?t=4
--- response_body
t=4
--- error_code: 404
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 10e: ESI still runs on cache revalidation, upstream 304, locally valid.
--- http_config eval: $::HttpConfig
--- config
location /esi_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("enable_esi", true)
        ledge:config_set("cache_key_spec", {
            ngx.var.scheme,
            ngx.var.host,
            ngx.var.uri,
        }) 
        run()
    ';
}
location /esi_10 {
    content_by_lua '
        ngx.exit(ngx.HTTP_NOT_MODIFIED)
    ';
}
--- more_headers
Cache-Control: max-age=0
If-None-Match: esi10
--- request
GET /esi_10_prx?t=5
--- response_body
t=5
--- error_code: 404
--- response_headers_like
X-Cache: MISS from .*
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 11a: Prime fragment
--- http_config eval: $::HttpConfig
--- config
location /fragment_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("FRAGMENT")
    ';
}
--- request
GET /fragment_prx
--- response_body
FRAGMENT
--- error_code: 200
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n


=== TEST 11b: Include fragment with client validators.
--- http_config eval: $::HttpConfig
--- config
location /esi_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.req.set_header("If-Modified-Since", ngx.http_time(ngx.time() + 150))
        run()
    ';
}
location /fragment_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /fragment {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("FRAGMENT MODIFIED")
    ';
}
location /esi_11 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_prx\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_11_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
FRAGMENT
2


=== TEST 12: ESI processed over buffer larger than buffer_size.
--- http_config eval: $::HttpConfig
--- config
location /esi_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 16)
        run()
    ';
}
location /esi_12 {
    default_type text/html;
    content_by_lua '
        local junk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ngx.print("<esi:vars>")
        ngx.say(junk)
        ngx.say("$(QUERY_STRING)")
        ngx.say(junk)
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_12_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
a=1
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA


=== TEST 12b: Incomplete ESI tag opening at the end of buffer (lookahead)
--- http_config eval: $::HttpConfig
--- config
location /esi_12b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 4)
        run()
    ';
}
location /esi_12b {
    default_type text/html;
    content_by_lua '
        ngx.print("---<esi:vars>")
        ngx.print("$(QUERY_STRING)")
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_12b_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: ---a=1


=== TEST 12c: Incomplete ESI tag opening at the end of buffer (lookahead)
--- http_config eval: $::HttpConfig
--- config
location /esi_12c_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 5)
        run()
    ';
}
location /esi_12c {
    default_type text/html;
    content_by_lua '
        ngx.print("---<esi:vars>")
        ngx.print("$(QUERY_STRING)")
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_12c_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: ---a=1


=== TEST 12d: Incomplete ESI tag opening at the end of buffer (lookahead)
--- http_config eval: $::HttpConfig
--- config
location /esi_12d_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 6)
        run()
    ';
}
location /esi_12d {
    default_type text/html;
    content_by_lua '
        ngx.print("---<esi:vars>")
        ngx.print("$(QUERY_STRING)")
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_12d_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: ---a=1


=== TEST 13: ESI processed over buffer larger than max_memory.
--- http_config eval: $::HttpConfig
--- config
location /esi_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("cache_max_memory", 16 / 1024)
        run()
    ';
}
location /esi_13 {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        local junk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ngx.print("<esi:vars>")
        ngx.say(junk)
        ngx.say("$(QUERY_STRING)")
        ngx.say(junk)
        ngx.print("</esi:vars>")
    ';
}
--- request
GET /esi_13_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
a=1
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
--- error_log
cache item deleted as it is larger than 16 bytes


=== TEST 14: choose - when - otherwise, first when matched
--- http_config eval: $::HttpConfig
--- config
location /esi_14_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_14 {
    default_type text/html;
    content_by_lua '
local content = [[Hello
<esi:choose>
<esi:when test="$(QUERY_STRING{a}) == 1">
True
</esi:when>
<esi:when test="2 == 2">
Still true, but first match wins
</esi:when>
<esi:otherwise>
Will never happen
</esi:otherwise>
</esi:choose>
Goodbye]]
        ngx.say(content)
    ';
}
--- request
GET /esi_14_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
Hello
True
Goodbye


=== TEST 15: choose - when - otherwise, second when matched
--- http_config eval: $::HttpConfig
--- config
location /esi_15_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_15 {
    default_type text/html;
    content_by_lua '
local content = [[Hello
<esi:choose>
<esi:when test="$(QUERY_STRING{a}) == 1">
1
</esi:when>
<esi:when test="$(QUERY_STRING{a}) == 2">
2
</esi:when>
<esi:when test="2 == 2">
Still true, but first match wins
</esi:when>
<esi:otherwise>
Will never happen
</esi:otherwise>
</esi:choose>
Goodbye]]
        ngx.say(content)
    ';
}
--- request
GET /esi_15_prx?a=2
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
Hello
2
Goodbye


=== TEST 16: choose - when - otherwise, otherwise catchall
--- http_config eval: $::HttpConfig
--- config
location /esi_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_16 {
    default_type text/html;
    content_by_lua '
local content = [[Hello
<esi:choose>
<esi:when test="$(QUERY_STRING{a}) == 1">
1
</esi:when>
<esi:when test="$(QUERY_STRING{a}) == 2">
2
</esi:when>
<esi:otherwise>
Otherwise
</esi:otherwise>
</esi:choose>
Goodbye]]
        ngx.say(content)
    ';
}
--- request
GET /esi_16_prx?a=3
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
Hello
Otherwise
Goodbye


=== TEST 17: choose - when - test, conditional syntax
--- http_config eval: $::HttpConfig
--- config
location /esi_17_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_17 {
    default_type text/html;
    content_by_lua '
        local conditions = {
            "1 == 1",
            "1==1",
            "1 != 2",
            "2 > 1",
            "1 > 2 | 3 > 2",
            "(1 > 2) | (3 > 2 & 2 > 1)",
            "(1>2)||(3>2&&2>1)",
            "! (2 > 1) | (3 > 2 & 2 > 1)",
            "\\\'hello\\\' == \\\'hello\\\'",
            "\\\'hello\\\' != \\\'goodbye\\\'",
            "\\\'repeat\\\' != \\\'function\\\'", -- use of lua words in strings
            "\\\' repeat sentence with function in it \\\' == \\\' repeat sentence with function in it \\\'", -- use of lua words in strings
            [["this string has \\\"quotes\\\"" == "this string has \\\"quotes\\\""]],
            "$(QUERY_STRING{msg}) == \\\'hello\\\'",
        }

        for _,c in ipairs(conditions) do
            ngx.say([[<esi:choose><esi:when test="]], c, [[">]], c, 
                    [[</esi:when><esi:otherwise>Failed</esi:otherwise></esi:choose>]])
            ngx.say("")
        end
    ';
}
--- request
GET /esi_17_prx?msg=hello
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1 == 1
1==1
1 != 2
2 > 1
1 > 2 | 3 > 2
(1 > 2) | (3 > 2 & 2 > 1)
(1>2)||(3>2&&2>1)
! (2 > 1) | (3 > 2 & 2 > 1)
'hello' == 'hello'
'hello' != 'goodbye'
'repeat' != 'function'
' repeat sentence with function in it ' == ' repeat sentence with function in it '
"this string has \"quotes\"" == "this string has \"quotes\""
hello == 'hello'


=== TEST 18: Surrogate-Control with lower version number still works.
--- http_config eval: $::HttpConfig
--- config
location /esi_18_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("origin_fetched", function(res)
            res.header["Surrogate-Control"] = [[content="ESI/0.8"]]
        end)
        ledge:run()
    ';
}
location /esi_18 {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_18_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: a=1


=== TEST 19: Surrogate-Control with higher version fails
--- http_config eval: $::HttpConfig
--- config
location /esi_19_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("origin_fetched", function(res)
            res.header["Surrogate-Control"] = [[content="ESI/1.1"]]
        end)
        ledge:run()
    ';
}
location /esi_19 {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_19_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>


=== TEST 20: Test we advertise Surrogate-Capability
--- http_config eval: $::HttpConfig
--- config
location /esi_20_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("origin_fetched", function(res)
            res.header["Surrogate-Control"] = [[content="ESI/1.1"]]
        end)
        ledge:run()
    ';
}
location /esi_20 {
    default_type text/html;
    content_by_lua '
        ngx.print(ngx.req.get_headers()["Surrogate-Capability"])
    ';
}
--- request
GET /esi_20_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: localhost="ESI/1.0"


=== TEST 21: Test Surrogate-Capability is appended when needed
--- http_config eval: $::HttpConfig
--- config
location /esi_21_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("origin_fetched", function(res)
            res.header["Surrogate-Control"] = [[content="ESI/1.1"]]
        end)
        ledge:run()
    ';
}
location /esi_21 {
    default_type text/html;
    content_by_lua '
        ngx.print(ngx.req.get_headers()["Surrogate-Capability"])
    ';
}
--- request
GET /esi_21_prx
--- more_headers
Surrogate-Capability: abc="ESI/0.8"
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: abc="ESI/0.8", localhost="ESI/1.0"


=== TEST 22: Test comments are removed.
--- http_config eval: $::HttpConfig
--- config
location /esi_22_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_22 {
    default_type text/html;
    content_by_lua '
        ngx.print([[1234<esi:comment text="comment text" />]])
    ';
}
--- request
GET /esi_22_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: 1234
