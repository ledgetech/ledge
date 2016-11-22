use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2); 

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
            require "resty.core"
        end
        ledge_mod = require "ledge.ledge"
        ledge = ledge_mod:new()
        ledge:config_set("redis_database", $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set("redis_qless_database", $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set("upstream_host", "127.0.0.1")
        ledge:config_set("upstream_port", 1984)
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
=== TEST 1: Read and override globals from init
--- http_config eval: $::HttpConfig
--- config
	location /config_1 {
        content_by_lua '
            ngx.print(ledge:config_get("redis_database"))
            ledge:config_set("redis_database", 2)
            ngx.say(ledge:config_get("redis_database"))
        ';
    }
--- request
GET /config_1
--- response_body
22

=== TEST 2: Module instance level config must not collide
--- http_config eval: $::HttpConfig
--- config
location /config_2 {
    content_by_lua '
        local ledge2 = ledge_mod:new()
        ledge:config_set("redis_database", 5)
        ngx.say(ledge2:config_get("redis_database"))
        ledge2:config_set("redis_database", 4)
        ngx.say(ledge2:config_get("redis_database"))
    ';
}
--- request
GET /config_2
--- response_body
0
4
