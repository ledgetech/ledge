use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 1;

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
        redis_socket = '$ENV{TEST_LEDGE_REDIS_SOCKET}'
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Update response provided to closure
--- http_config eval: $::HttpConfig
--- config
location /events_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:bind("response_ready", function(res)
            res.header["X-Modified"] = "Modified"
        end)
        ledge:run()
    ';
}
location /events_1 {
    echo "ORIGIN";
}
--- request
GET /events_1_prx
--- error_code: 200
--- response_headers
X-Modified: Modified
--- no_error_log


=== TEST 2: Customise params prior to request
--- http_config eval: $::HttpConfig
--- config
location /events_2 {
    content_by_lua '
        ledge:bind("before_request", function(params)
            params.path = "/modified"
        end)
        ledge:run()
    ';
}
location /modified {
    echo "ORIGIN";
}
--- request
GET /events_2
--- error_code: 200
--- response_body
ORIGIN
--- no_error_log


=== TEST 3: Trap bad code in user callback
--- http_config eval: $::HttpConfig
--- config
location /events_3 {
    content_by_lua '
        ledge:bind("before_request", function(params)
            params.path = "/modified"
            foo.foo = "bar"
        end)
        ledge:run()
    ';
}
location /modified {
    echo "ORIGIN";
}
--- request
GET /events_3
--- error_code: 200
--- response_body
ORIGIN
--- error_log: Error in user callback for 'before_request'

