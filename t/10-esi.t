use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests =>  repeat_each() * (blocks() * 4) + 35;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_LEDGE_CHUNKED} ||= 'on';
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
    resolver 8.8.8.8;
    if_modified_since off;
    chunked_transfer_encoding $ENV{TEST_LEDGE_CHUNKED};
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;/usr/local/share/lua/5.1/?.lua;;";
    init_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
            require("luacov.runner").init()
        end

        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require "resty.core"
        end
        ledge_mod = require "ledge.ledge"
        ledge = ledge_mod:new()
        ledge:config_set("redis_database", $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set("redis_qless_database", $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set("upstream_host", "127.0.0.1")
        ledge:config_set("upstream_port", 1984)
        ledge:config_set("esi_enabled", true)
        ledge:config_set("buffer_size", 5) -- Try to trip scanning up with small buffers

        function run()
            ledge:bind("origin_fetched", function(res)
                res.header["Surrogate-Control"] = [[content="ESI/1.0"]]
            end)
            ledge:run()
        end
    }

    init_worker_by_lua_block {
        if $ENV{TEST_COVERAGE} == 1 then
            jit.off()
        end
        ledge:run_workers()
    }
};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Single line comments removed
--- http_config eval: $::HttpConfig
--- config
location /esi_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        --ledge:config_set("buffer_size", 10)
        run()
    ';
}
location /esi_1 {
    default_type text/html;
    content_by_lua '
        ngx.say("<!--esiCOMMENTED-->")
        ngx.say("<!--esiCOMMENTED-->")
    ';
}
--- request
GET /esi_1_prx
--- response_body
COMMENTED
COMMENTED
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- no_error_log
[error]


=== TEST 1b: Single line comments removed, esi instructions processed
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
--- response_body: a=1b
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 2b: Multi line comments removed, ESI instructions processed
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
location /test {
    content_by_lua '
        ngx.print("OK")
    ';
}
--- request
GET /esi_2_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1234 OK
2345

a=1
--- no_error_log
[error]


=== TEST 2c: Multi line escaping comments, nested. ESI instructions still processed
--- http_config eval: $::HttpConfig
--- config
location /esi_2c_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_2c {
    default_type text/html;
    content_by_lua_block {
        ngx.say("BEFORE")
        ngx.print("<!--esi")
        ngx.say("<esi:vars>$(QUERY_STRING{a})</esi:vars>")
        ngx.print("<!--esi")
        ngx.say("<esi:vars>$(QUERY_STRING{b})</esi:vars>")
        ngx.print("-->")
        ngx.say("MIDDLE")
        ngx.say("<esi:vars>$(QUERY_STRING{c})</esi:vars>")
        ngx.print("-->")
        ngx.say("AFTER")
    }
}
--- request
GET /esi_2c_prx?a=1&b=2&c=3
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
BEFORE
1
2
MIDDLE
3
AFTER
--- no_error_log
[error]


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
        ngx.say("START")
        ngx.say("<esi:remove>REMOVED</esi:remove>")
        ngx.say("<esi:remove>REMOVED</esi:remove>")
        ngx.say("END")
    ';
}
--- request
GET /esi_3_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
START


END
--- no_error_log
[error]


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
        ngx.say("4")
        ngx.say("<esi:remove>")
        ngx.say("5")
        ngx.say("</esi:remove>")
        ngx.say("6")
    ';
}
--- request
GET /esi_4_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1

3
4

6
--- no_error_log
[error]


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
    content_by_lua_block {
        ngx.say("FRAGMENT: ", ngx.req.get_uri_args()["a"] or "")
    }
}
location /esi_5 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print([[<esi:include src="/fragment_1" />]])
        ngx.say("2")
        ngx.print([[<esi:include src="/fragment_1?a=2" />]])
        ngx.print("3")
        ngx.print([[<esi:include src="http://127.0.0.1:1984/fragment_1?a=3" />]])
    ';
}
--- request
GET /esi_5_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
FRAGMENT: 
2
FRAGMENT: 2
3FRAGMENT: 3
--- no_error_log
[error]


=== TEST 5b: Test fragment always issues GET and only inherits correct req headers
--- http_config eval: $::HttpConfig
--- config
location /esi_5b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment_1 {
    content_by_lua '
        ngx.say("method: ", ngx.req.get_method())
        local h = ngx.req.get_headers()
        for k,v in pairs(h) do
            ngx.say(k, ": ", v)
        end
    ';
}
location /esi_5b {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:include src=\\"/fragment_1\\" />")
    ';
}
--- request
POST /esi_5b_prx
--- more_headers
Cache-Control: no-cache
Cookie: foo
Authorization: bar
Range: bytes=0-
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body_like
method: GET
host: localhost
cookie: foo
x-esi-parent-uri: http://localhost/esi_5b_prx
cache-control: no-cache
x-esi-recursion-level: 1
user-agent: lua-resty-http/\d+\.\d+ \(Lua\) ngx_lua/\d+ ledge_esi/\d+\.\d+[\.\d]*
authorization: bar
--- no_error_log
[error]


=== TEST 5c: Include fragment with absolute URI, schemalss, and no path
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
location =/ {
    echo "ROOT FRAGMENT";
}
location /esi_5 {
    default_type text/html;
    content_by_lua '
        ngx.print([[<esi:include src="http://127.0.0.1:1984/fragment_1" />]])
        ngx.print([[<esi:include src="//127.0.0.1:1984/fragment_1" />]])
        ngx.print([[<esi:include src="http://127.0.0.1:1984/" />]])
        ngx.print([[<esi:include src="http://127.0.0.1:1984" />]])
        ngx.print([[<esi:include src="//127.0.0.1:1984" />]])
    ';
}
--- request
GET /esi_5_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
FRAGMENT
FRAGMENT
ROOT FRAGMENT
ROOT FRAGMENT
ROOT FRAGMENT
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 7f: Leave instructions intact if allowed types does not match (slow path)
--- http_config eval: $::HttpConfig
--- config
location /esi_7f_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_content_types", { "text/plain" })
        run()
    ';
}
location /esi_7f {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_7f_prx?a=1
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"
--- no_error_log
[error]


=== TEST 7g: Leave instructions intact if allowed types does not match (fast path)
--- http_config eval: $::HttpConfig
--- config
location /esi_7f_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_content_types", { "text/plain" })
        run()
    ';
}
--- request
GET /esi_7f_prx?a=1
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
Cache-Control: private, max-age=0
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- no_error_log
[error]


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
        ngx.say("</esi:vars>");
        ngx.say("<esi:vars>$(HTTP_COOKIE{SQ_SYSTEM_SESSION})</esi:vars>$(HTTP_COOKIE)<esi:vars>$(QUERY_STRING)</esi:vars>")
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

hello$(HTTP_COOKIE)t=1
--- no_error_log
[error]


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
        ngx.say("<esi:include src=\\"/fragment1b?$(QUERY_STRING)&test=$(HTTP_X_ESI_TEST)\\" /> <a href=\\"$(QUERY_STRING)\\" />")
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
FRAGMENT:t=1&test=foobar <a href="$(QUERY_STRING)" />
--- no_error_log
[error]



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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
    default_type text/html;
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
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 11c: Include fragment with " H" in URI (bad req in Nginx unless encoded).
--- http_config eval: $::HttpConfig
--- config
location /esi_11c_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location "/frag Hment" {
    content_by_lua '
        ngx.say("FRAGMENT")
    ';
}
location /esi_11c {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/frag Hment\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_11c_prx
--- response_body
1
FRAGMENT
2
--- error_code: 200
--- no_error_log
[error]


=== TEST 11d: Use callback feature to modify fragment request params
--- http_config eval: $::HttpConfig
--- config
location /esi_11d_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_pre_include_callback", function(req_params)
            req_params.headers["X-Foo"] = "bar"
        end)
        run()
    ';
}
location "/fragment" {
    content_by_lua '
        ngx.say(ngx.req.get_headers()["X-Foo"])
        ngx.say("FRAGMENT")
    ';
}
location /esi_11d {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment\\" />")
        ngx.say("2")
    ';
}
--- request
GET /esi_11d_prx
--- response_body
1
bar
FRAGMENT
2
--- error_code: 200
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 12e: Incomplete ESI tag opening at the end of response (regression)
--- http_config eval: $::HttpConfig
--- config
location /esi_12e_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 9)
        run()
    ';
}
location /esi_12e {
    default_type text/html;
    content_by_lua '
        ngx.print("---<esi:vars>")
        ngx.print("$(QUERY_STRING)")
        ngx.print("</esi:vars><es")
    ';
}
--- request
GET /esi_12e_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: ---a=1<es
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- no_error_log
[error]


=== TEST 16b: multiple choose - when - otherwise
--- http_config eval: $::HttpConfig
--- config
location /esi_16b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_16b {
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
</esi:choose><esi:choose>
<esi:when test="$(QUERY_STRING{a}) == 3">
3
</esi:when>
<esi:when test="$(QUERY_STRING{a}) == 4">
4
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
GET /esi_16b_prx?a=3
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
Hello

Otherwise

3

Goodbye
--- no_error_log
[error]


=== TEST 16c: multiple single line choose - when - otherwise
--- http_config eval: $::HttpConfig
--- config
location /esi_16c_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_16c {
    default_type text/html;
    content_by_lua '
        local content = [[<esi:choose><esi:when test="$(QUERY_STRING{a}) == 1">1</esi:when><esi:otherwise>Otherwise</esi:otherwise></esi:choose>: <esi:choose><esi:when test="$(QUERY_STRING{a}) == 3">3</esi:when><esi:otherwise>NOPE</esi:otherwise></esi:choose>]]
        ngx.print(content)
    ';
}
--- request
GET /esi_16c_prx?a=3
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: Otherwise: 3
--- no_error_log
[error]


=== TEST 17: choose - when - test, conditional syntax
--- http_config eval: $::HttpConfig
--- config
location /esi_17_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_17 {
    default_type text/html;
    content_by_lua_block {
        local conditions = {
            "1 == 1",
            "1==1",
            "1 != 2",
            "2 > 1",
            "1 > 2 | 3 > 2",
            "(1 > 2) | (3.02 > 2.4124 & 1 <= 1)",
            "(1>2)||(3>2&&2>1)",
            "! (1 < 2) | (3 > 2 & 2 >= 1)",
            "'hello' == 'hello'",
            "'hello' != 'goodbye'",
            "'repeat' != 'function'", -- use of lua words in strings
            "'repeat' != function", -- use of lua words unquoted
            "' repeat sentence with function in it ' == ' repeat sentence with function in it '", -- use of lua words in strings
            "$(QUERY_STRING{msg}) == 'hello'",
            [['string \' escaping' == 'string \' escaping']],
            [['string \" escaping' == 'string \" escaping']],
            [[$(QUERY_STRING{msg2}) == 'hel\'lo']],
            "'hello' =~ '/llo/'",
            [['HeL\'\'\'Lo' =~ '/hel[\']{1,3}lo/i']],
            [['http://example.com?foo=bar' =~ '/^(http[s]?)://([^:/]+)(?::(\d+))?(.*)/']],
            [['htxtp://example.com?foo=bar' =~ '/^(http[s]?)://([^:/]+)(?::(\d+))?(.*)/']],
            "(1 > 2) | (3.02 > 2.4124 & 1 <= 1) && ('HeLLo' =~ '/hello/i')",
            "2 =~ '/[0-9]/'",
        }

        for _,c in ipairs(conditions) do
            ngx.say([[<esi:choose><esi:when test="]], c, [[">]], c,
                    [[</esi:when><esi:otherwise>Failed</esi:otherwise></esi:choose>]])
        end
    }
}
--- request
GET /esi_17_prx?msg=hello&msg2=hel'lo
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1 == 1
1==1
1 != 2
2 > 1
1 > 2 | 3 > 2
(1 > 2) | (3.02 > 2.4124 & 1 <= 1)
(1>2)||(3>2&&2>1)
! (1 < 2) | (3 > 2 & 2 >= 1)
'hello' == 'hello'
'hello' != 'goodbye'
'repeat' != 'function'
Failed
' repeat sentence with function in it ' == ' repeat sentence with function in it '
hello == 'hello'
'string \' escaping' == 'string \' escaping'
'string \" escaping' == 'string \" escaping'
hel'lo == 'hel\'lo'
'hello' =~ '/llo/'
'HeL\'\'\'Lo' =~ '/hel[\']{1,3}lo/i'
'http://example.com?foo=bar' =~ '/^(http[s]?)://([^:/]+)(?::(\d+))?(.*)/'
Failed
(1 > 2) | (3.02 > 2.4124 & 1 <= 1) && ('HeLLo' =~ '/hello/i')
2 =~ '/[0-9]/'


=== TEST 17b: Lexer complains about unparseable conditions
--- http_config eval: $::HttpConfig
--- config
location /esi_17b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua 'run()';
}
location /esi_17b {
    default_type text/html;
    content_by_lua_block {
        local content = [[<esi:choose>
<esi:when test="'hello' 'there'">OK</esi:when>
<esi:when test="3 'hello'">OK</esi:when>
<esi:when test="'hello' 4">OK</esi:when>
<esi:otherwise>Otherwise</esi:otherwise>
</esi:choose>
]]
        ngx.print(content)
    }
}
--- request
GET /esi_17b_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
Otherwise
--- error_log
Parse error: found string after string in: "'hello' 'there'"
Parse error: found string after number in: "3 'hello'"
Parse error: found number after string in: "'hello' 4"


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
--- no_error_log
[error]


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
--- no_error_log
[error]


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
--- response_body_like: ^(.*)="ESI/1.0"$
--- no_error_log
[error]


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
--- response_body_like: ^abc="ESI/0.8", (.*)="ESI/1.0"$
--- no_error_log
[error]


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
        ngx.print([[1234<esi:comment text="comment text" /> 5678<esi:comment text="comment text 2" />]])
    ';
}
--- request
GET /esi_22_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: 1234 5678
--- no_error_log
[error]


=== TEST 23a: Surrogate-Control removed when ESI enabled but no work needed (slow path)
--- http_config eval: $::HttpConfig
--- config
location /esi_23_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_23 {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("NO ESI")
    ';
}
--- request
GET /esi_23_prx?a=1
--- response_body: NO ESI
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- no_error_log
[error]


=== TEST 23b: Surrogate-Control removed when ESI enabled but no work needed (fast path)
--- http_config eval: $::HttpConfig
--- config
location /esi_23_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
--- request
GET /esi_23_prx?a=1
--- response_body: NO ESI
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- no_error_log
[error]


=== TEST 24a: Fragment recursion limit
--- http_config eval: $::HttpConfig
--- config
location /esi_24_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        -- recursion limit fails on tiny buffer sizes because it can't be scanned
        ledge:config_set("buffer_size", 4096)
        run()
    }
}
location /fragment_24_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 4096)
        run()
    ';
}
location /fragment_24 {
    default_type text/html;
    content_by_lua '
        ngx.say("c: ", ngx.req.get_headers()["X-ESI-Recursion-Level"] or "0")
        ngx.print("<esi:include src=\\"/esi_24_prx\\" />")
        ngx.print("<esi:include src=\\"/esi_24_prx\\" />")
    ';
}
location /esi_24 {
    default_type text/html;
    content_by_lua '
        ngx.say("p: ", ngx.req.get_headers()["X-ESI-Recursion-Level"] or "0")
        ngx.print("<esi:include src=\\"/fragment_24_prx\\" />")
    ';
}
--- request
GET /esi_24_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
p: 0
c: 1
p: 2
c: 3
p: 4
c: 5
p: 6
c: 7
p: 8
c: 9
p: 10
--- error_log
ESI recursion limit (10) exceeded


=== TEST 24b: Lower fragment recursion limit
--- http_config eval: $::HttpConfig
--- config
location /esi_24_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 4096)
        ledge:config_set("esi_recursion_limit", 5)
        run()
    ';
}
location /fragment_24_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 4096)
        ledge:config_set("esi_recursion_limit", 5)
        run()
    ';
}
location /fragment_24 {
    default_type text/html;
    content_by_lua '
        ngx.say("c: ", ngx.req.get_headers()["X-ESI-Recursion-Level"] or "0")
        ngx.print("<esi:include src=\\"/esi_24_prx\\" />")
        ngx.print("<esi:include src=\\"/esi_24_prx\\" />")
    ';
}
location /esi_24 {
    default_type text/html;
    content_by_lua '
        ngx.say("p: ", ngx.req.get_headers()["X-ESI-Recursion-Level"] or "0")
        ngx.print("<esi:include src=\\"/fragment_24_prx\\" />")
    ';
}
--- request
GET /esi_24_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
p: 0
c: 1
p: 2
c: 3
p: 4
c: 5
--- error_log
ESI recursion limit (5) exceeded


=== TEST 25: Multiple esi includes on a single line
--- http_config eval: $::HttpConfig
--- config
location /esi_25_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment_25a {
    default_type text/html;
    content_by_lua '
        ngx.print("25a")
    ';
}
location /fragment_25b {
    default_type text/html;
    content_by_lua '
        ngx.print("25b")
    ';
}
location /esi_25 {
    default_type text/html;
    content_by_lua '
        ngx.print("<esi:include src=\\"/fragment_25a\\" /> <esi:include src=\\"/fragment_25b\\" />")
    ';
}
--- request
GET /esi_25_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: 25a 25b
--- no_error_log
[error]


=== TEST 26: Include tag whitespace
--- http_config eval: $::HttpConfig
--- config
location /esi_26_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /fragment_1 {
    echo "FRAGMENT";
}
location /esi_26 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_1\\"/>")
        ngx.say("2")
        ngx.print("<esi:include    	   src=\\"/fragment_1\\"   	  />")
    ';
}
--- request
GET /esi_26_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
FRAGMENT
2
FRAGMENT
--- no_error_log
[error]


=== TEST 27a: Prime cache, immediately expired
--- http_config eval: $::HttpConfig
--- config
location /esi_27_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        run()
    ';
}
location /esi_27 {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.say("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_27_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
a=1
--- no_error_log
[error]


=== TEST 27b: ESI still works when serving stale
--- http_config eval: $::HttpConfig
--- config
location /esi_27_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
--- more_headers
Cache-Control: stale-while-revalidate=60
--- request
GET /esi_27_prx?a=1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
a=1
--- no_error_log
[error]


=== TEST 27c: ESI still works when serving stale-if-error
--- http_config eval: $::HttpConfig
--- config
location /esi_27_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_27 {
    return 500;
}
--- more_headers
Cache-Control: stale-if-error=9999
--- request
GET /esi_27_prx?a=1
--- wait: 1
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
a=1
--- wait: 2
--- no_error_log
[error]


=== TEST 28: Remaining parent response returned on fragment error
--- http_config eval: $::HttpConfig
--- config
location /esi_28_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '

        run()
    ';
}
location /fragment_1 {
    return 500;
    echo "FRAGMENT";
}
location /esi_28 {
    default_type text/html;
    content_by_lua '
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_1\\"/>")
        ngx.say("2")
    ';
}
--- request
GET /esi_28_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
2
--- error_log
500 from /fragment_1


=== TEST 29: Remaining parent response chunks returned on fragment error
--- http_config eval: $::HttpConfig
--- config
location /esi_29_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 16)
        run()
    ';
}
location /fragment_1 {
    return 500;
    echo "FRAGMENT";
}
location /esi_29 {
    default_type text/html;
    content_by_lua '
        local junk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        ngx.say(junk)
        ngx.say("1")
        ngx.print("<esi:include src=\\"/fragment_1\\"/>")
        ngx.say(junk)
        ngx.say("2")
    ';
}
--- request
GET /esi_29_prx
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
1
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
2
--- error_log
500 from /fragment_1


=== TEST 30: Prime with ESI args - which shouldn't enter cache key or reach the origin
--- http_config eval: $::HttpConfig
--- config
location /esi_30_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:config_set("enable_esi", true)
        run()
    }
}
location /esi_30 {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("<esi:vars>$(ESI_ARGS{a}|noarg)</esi:vars>: ")
        ngx.print(ngx.req.get_uri_args()["esi_a"])
    }
}
--- request
GET /esi_30_prx?esi_a=1
--- response_body: 1: nil
--- error_code: 200
--- response_headers_like
X-Cache: MISS from .*
--- no_error_log
[error]

=== TEST 30b: ESI args vary, but cache is a HIT
--- http_config eval: $::HttpConfig
--- config
location /esi_30_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:config_set("enable_esi", true)
        run()
    }
}
location /esi_30 {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("MISS")
    }
}
--- request eval
["GET /esi_30_prx?esi_a=2", "GET /esi_30_prx?esi_a=3", "GET /esi_30_prx?bad_esi_a=4"]
--- response_body eval
["2: nil", "3: nil", "MISS"]
--- error_code eval
["200", "200", "200"]
--- response_headers_like eval
["X-Cache: HIT from .*", "X-Cache: HIT from .*", "X-Cache: MISS from .*"]
--- no_error_log
[error]


=== TEST 31a: Multiple sibling and child conditionals, winning expressions at various depths
--- http_config eval: $::HttpConfig
--- config
location /esi_31a_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        run()
    ';
}
location /esi_31a {
    default_type text/html;
    content_by_lua_block {
        local content = [[
BEFORE CONTENT
<esi:choose>
    <esi:when test="$(QUERY_STRING{a}) == 'a'">a</esi:when>
</esi:choose>
<esi:choose>
    <esi:when test="$(QUERY_STRING{b}) == 'b'">b</esi:when>
    RANDOM ILLEGAL CONTENT
    <esi:when test="$(QUERY_STRING{c}) == 'c'">c
        <esi:choose>
            </esi:vars alt="BAD ILLEGAL NESTING">
            <esi:when test="$(QUERY_STRING{l1d}) == 'l1d'">l1d</esi:when>
            <esi:when test="$(QUERY_STRING{l1e}) == 'l1e'">l1e
                <esi:choose>
                    <esi:when test="$(QUERY_STRING{l2f}) == 'l2f'">l2f</esi:when>
                    <esi:otherwise>l2 OTHERWISE</esi:otherwise>
                </esi:choose>
            </esi:when>
            <esi:otherwise>l1 OTHERWISE
                <esi:choose>
                    <esi:when test="$(QUERY_STRING{l2g}) == 'l2g'">l2g</esi:when>
                    </esi:when alt="MORE BAD ILLEGAL NESTING">
                </esi:choose>
            </esi:otherwise>
        </esi:choose>
    </esi:when>
</esi:choose>
AFTER CONTENT]]

        ngx.print(content)
    }
}
--- request eval
[
"GET /esi_31a_prx?a=a",
"GET /esi_31a_prx?b=b",
"GET /esi_31a_prx?a=a&b=b",
"GET /esi_31a_prx?l1d=l1d",
"GET /esi_31a_prx?c=c&l1d=l1d",
"GET /esi_31a_prx?c=c&l1e=l1e&l2f=l2f",
"GET /esi_31a_prx?c=c&l1e=l1e",
"GET /esi_31a_prx?c=c",
"GET /esi_31a_prx?c=c&l2g=l2g",
]
--- response_body eval
[
"BEFORE CONTENT
a

AFTER CONTENT",

"BEFORE CONTENT

b
AFTER CONTENT",

"BEFORE CONTENT
a
b
AFTER CONTENT",

"BEFORE CONTENT


AFTER CONTENT",

"BEFORE CONTENT

c
        l1d
    
AFTER CONTENT",

"BEFORE CONTENT

c
        l1e
                l2f
            
    
AFTER CONTENT",

"BEFORE CONTENT

c
        l1e
                l2 OTHERWISE
            
    
AFTER CONTENT",

"BEFORE CONTENT

c
        l1 OTHERWISE
                
            
    
AFTER CONTENT",

"BEFORE CONTENT

c
        l1 OTHERWISE
                l2g
            
    
AFTER CONTENT",
]
--- no_error_log


=== TEST 31b: As above, no whitespace
--- http_config eval: $::HttpConfig
--- config
location /esi_31b_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 200)
        run()
    ';
}
location /esi_31b {
    default_type text/html;
    content_by_lua_block {
        local content = [[BEFORE CONTENT<esi:choose><esi:when test="$(QUERY_STRING{a}) == 'a'">a</esi:when></esi:choose><esi:choose><esi:when test="$(QUERY_STRING{b}) == 'b'">b</esi:when>RANDOM ILLEGAL CONTENT<esi:when test="$(QUERY_STRING{c}) == 'c'">c<esi:choose><esi:when test="$(QUERY_STRING{l1d}) == 'l1d'">l1d</esi:when><esi:when test="$(QUERY_STRING{l1e}) == 'l1e'">l1e<esi:choose><esi:when test="$(QUERY_STRING{l2f}) == 'l2f'">l2f</esi:when><esi:otherwise>l2 OTHERWISE</esi:otherwise></esi:choose></esi:when><esi:otherwise>l1 OTHERWISE<esi:choose><esi:when test="$(QUERY_STRING{l2g}) == 'l2g'">l2g</esi:when></esi:choose></esi:otherwise></esi:choose></esi:when></esi:choose>AFTER CONTENT]]

        ngx.print(content)
    }
}
--- request eval
[
"GET /esi_31b_prx?a=a",
"GET /esi_31b_prx?b=b",
"GET /esi_31b_prx?a=a&b=b",
"GET /esi_31b_prx?l1d=l1d",
"GET /esi_31b_prx?c=c&l1d=l1d",
"GET /esi_31b_prx?c=c&l1e=l1e&l2f=l2f",
"GET /esi_31b_prx?c=c&l1e=l1e",
"GET /esi_31b_prx?c=c",
"GET /esi_31b_prx?c=c&l2g=l2g",
]
--- response_body eval
["BEFORE CONTENTaAFTER CONTENT",
"BEFORE CONTENTbAFTER CONTENT",
"BEFORE CONTENTabAFTER CONTENT",
"BEFORE CONTENTAFTER CONTENT",
"BEFORE CONTENTcl1dAFTER CONTENT",
"BEFORE CONTENTcl1el2fAFTER CONTENT",
"BEFORE CONTENTcl1el2 OTHERWISEAFTER CONTENT",
"BEFORE CONTENTcl1 OTHERWISEAFTER CONTENT",
"BEFORE CONTENTcl1 OTHERWISEl2gAFTER CONTENT"]
--- no_error_log


=== TEST 32: Tag parsing boundaries
--- http_config eval: $::HttpConfig
--- config
location /esi_32_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("buffer_size", 50)
        run()
    ';
}
location /esi_32 {
    default_type text/html;
    content_by_lua_block {
        local content = [[
BEFORE CONTENT
<esi:choose
><esi:when           
                    test="$(QUERY_STRING{a}) == 'a'"
            >a
<esi:include 


                src="/fragment"         

/></esi:when
>
</esi:choose


>
AFTER CONTENT
]]

        ngx.print(content)
    }
}
location /fragment {
    echo "OK";
}
--- request
GET /esi_32_prx?a=a
--- response_body
BEFORE CONTENT
a
OK

AFTER CONTENT
--- no_error_log

=== TEST 33: Invalid Surrogate-Capability header is ignored
--- http_config eval: $::HttpConfig
--- config
location /esi_33_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:config_set("esi_allow_surrogate_delegation", true)
        ledge:run()
    }
}
location /esi_33 {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Surrogate-Control"] = 'content="ESI/1.0"'
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    }
}
--- request
GET /esi_33_prx?foo=bar
--- more_headers
Surrogate-capability: localhost="ESI/1foo"
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body: foo=bar
--- no_error_log
[error]


=== TEST 34: Leave instructions intact if surrogate-capability doesn't match http host
--- http_config eval: $::HttpConfig
--- config
location /esi_34_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("esi_allow_surrogate_delegation", true)
        run()
    ';
}
location /esi_34 {
    default_type text/html;
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("<esi:vars>$(QUERY_STRING)</esi:vars>")
    ';
}
--- request
GET /esi_34_prx?a=1
--- more_headers
Surrogate-Capability: esi.example.com="ESI/1.0"
--- response_body: <esi:vars>$(QUERY_STRING)</esi:vars>
--- response_headers
Surrogate-Control: content="ESI/1.0"
--- no_error_log
[error]
