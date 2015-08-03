use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

my $pwd = cwd();

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
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
	";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime gzipped response
--- http_config eval: $::HttpConfig
--- config
	location /gzip_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
    location /gzip {
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
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 2: Client doesn't support gzip, gets plain response
--- http_config eval: $::HttpConfig
--- config
	location /gzip_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /gzip_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 2: Client doesn't support gzip, gunzip is disabled, gets zipped response
--- http_config eval: $::HttpConfig
--- config
	location /gzip_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("gunzip_enabled", false)
            ledge:run()
        ';
    }
--- request
GET /gzip_prx
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 3: Client does support gzip, gets zipped response
--- http_config eval: $::HttpConfig
--- config
	location /gzip_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 4: Client does support gzip, but sends a range, gets plain full response
--- http_config eval: $::HttpConfig
--- config
	location /gzip_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- more_headers
Range: bytes=0-0
--- error_code: 200
--- response_body
OK
--- no_error_log
[error]


=== TEST 5: Prime gzipped response with ESI, auto unzips.
--- http_config eval: $::HttpConfig
--- config
	location /gzip_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }
    location /gzip_5 {
        gzip on;
        gzip_proxied any;
        gzip_min_length 1;
        gzip_http_version 1.0;
        default_type text/html;
        more_set_headers "Cache-Control: public, max-age=600";
        more_set_headers "Content-Type: text/html";
        more_set_headers 'Surrogate-Control: content="ESI/1.0"';
        echo "OK<esi:vars></esi:vars>";
    }
--- request
GET /gzip_5_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
OK
--- no_error_log
[error]


=== TEST 6: Client does support gzip, but content had to be unzipped on save
--- http_config eval: $::HttpConfig
--- config
	location /gzip_5_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:run()
        ';
    }
--- request
GET /gzip_5_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
OK
--- no_error_log
[error]


=== TEST 7: HEAD request for gzipped response with ESI, auto unzips.
--- http_config eval: $::HttpConfig
--- config
	location /gzip_7_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("esi_enabled", true)
            ledge:run()
        ';
    }
    location /gzip_7 {
        gzip on;
        gzip_proxied any;
        gzip_min_length 1;
        gzip_http_version 1.0;
        default_type text/html;
        more_set_headers "Cache-Control: public, max-age=600";
        more_set_headers "Content-Type: text/html";
        more_set_headers 'Surrogate-Control: content="ESI/1.0"';
        echo "OK";
    }
--- request
HEAD /gzip_7_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
--- no_error_log
[error]
