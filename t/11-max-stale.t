use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 7);

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

        ledge.miss_count = 0
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
=== TEST 1: Honour max-stale request header for an expired item
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    }
}
location /stale_1 {
    content_by_lua_block {
        ledge.miss_count = ledge.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=60"
        ngx.print("TEST 1: ", ledge.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request eval
["GET /stale_1_prx", "GET /stale_1_prx"]
--- wait: 2
--- response_body eval
["TEST 1: 1", "TEST 1: 1"]
--- response_headers_like eval
["", 'Warning: 110 (?:[^\s]*) "Response is stale"']
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 1b: Confirm nothing was revalidated in the background
--- http_config eval: $::HttpConfig
--- config
location /stale_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /stale_1_prx
--- response_body: TEST 1: 1
--- response_headers_like
Warning: 110 (?:[^\s]*) "Response is stale"
--- error_code eval
404
--- no_error_log
[error]


=== TEST 5: proxy-revalidate must revalidate (not serve stale)
--- http_config eval: $::HttpConfig
--- config
location /stale_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0, proxy-revalidate"
        end)
        ledge:run()
    }
}
location /stale_5 {
    content_by_lua_block {
        ledge.miss_count = ledge.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600, proxy-revalidate"
        ngx.print("TEST 5: ", ledge.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120
--- request eval
["GET /stale_5_prx", "GET /stale_5_prx"]
--- response_body eval
["TEST 5: 1", "TEST 5: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 6: must-revalidate must revalidate (not serve stale)
--- http_config eval: $::HttpConfig
--- config
location /stale_6_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0, must-revalidate"
        end)
        ledge:run()
    }
}
location /stale_6 {
    content_by_lua_block {
        ledge.miss_count = ledge.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600, must-revalidate"
        ngx.print("TEST 6: ", ledge.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120
--- request eval
["GET /stale_6_prx", "GET /stale_6_prx"]
--- response_body eval
["TEST 6: 1", "TEST 6: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]


=== TEST 7: Can serve stale but must revalidate because of Age
--- http_config eval: $::HttpConfig
--- config
location /stale_7_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:bind("before_save", function(res)
            -- immediately expire
            res.header["Cache-Control"] = "max-age=0"
        end)
        ledge:run()
    }
}
location /stale_7 {
    content_by_lua_block {
        ledge.miss_count = ledge.miss_count + 1
        ngx.status = 404
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 7: ", ledge.miss_count)
    }
}
--- more_headers
Cache-Control: max-stale=120, max-age=1
--- request eval
["GET /stale_7_prx", "GET /stale_7_prx"]
--- response_body eval
["TEST 7: 1", "TEST 7: 2"]
--- raw_response_headers_unlike eval
["Warning: 110", "Warning: 110"]
--- error_code eval
[404, 404]
--- no_error_log
[error]
--- wait: 2
