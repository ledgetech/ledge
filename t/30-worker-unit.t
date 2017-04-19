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

    local ledge = require("ledge")

    ledge.set("redis_params", {
        redis_connection = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })
}

}; # HttpConfig


no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load module without errors.
--- http_config eval: $::HttpConfig
--- config
location /worker_1 {
    content_by_lua_block {
        assert(require("ledge.worker"))
    }
}
--- request
GET /worker_1
--- no_error_log
[error]


=== TEST 2: Create worker with default config
--- http_config eval: $::HttpConfig
--- config
location /worker_2 {
    content_by_lua_block {
        assert(require("ledge.worker").new())
    }
}
--- request
GET /worker_2
--- no_error_log
[error]


=== TEST 3: Create worker with bad config value
--- http_config eval: $::HttpConfig
--- config
location /worker_3 {
    content_by_lua_block {
        require("ledge.worker").new({
            interval = "one",
        })
    }
}
--- request
GET /worker_3
--- error_code: 500
--- error_log
invalid config item or value type: interval


=== TEST 4: Create worker with bad config key
--- http_config eval: $::HttpConfig
--- config
location /worker_4 {
    content_by_lua_block {
        require("ledge.worker").new({
            foo = "one",
        })
    }
}
--- request
GET /worker_4
--- error_code: 500
--- error_log
invalid config item or value type: foo
