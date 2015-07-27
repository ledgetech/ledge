use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

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
=== TEST 1: ORIGIN_MODE_NORMAL
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_NORMAL)
            ledge:run()
        ';
    }
    location /origin_mode {
        more_set_headers  "Cache-Control: public, max-age=600";
        echo "OK";
    }
--- request
GET /origin_mode_prx
--- response_body
OK


=== TEST 2: ORIGIN_MODE_AVOID
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_AVOID)
            ledge:run()
        ';
    }
    location /origin_mode {
        echo "ORIGIN";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_prx
--- response_body
OK


=== TEST 3: ORIGIN_MODE_BYPASS when cached with 112 warning
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
            ledge:run()
        ';
    }
    location /origin_mode {
        echo "ORIGIN";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_prx
--- response_headers_like
Warning: 112 .*
--- response_body
OK

=== TEST 4: ORIGIN_MODE_BYPASS when we have nothing
--- http_config eval: $::HttpConfig
--- config
	location /origin_mode_bypass_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua '
            ledge:config_set("origin_mode", ledge.ORIGIN_MODE_BYPASS)
            ledge:run()
        ';
    }
    location /origin_mode_bypass {
        echo "ORIGIN";
    }
--- more_headers
Cache-Control: no-cache
--- request
GET /origin_mode_bypass_prx
--- error_code: 503

