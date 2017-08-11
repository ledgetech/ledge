use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            url = "redis://127.0.0.1:6379/$ENV{TEST_LEDGE_REDIS_DATABASE}",
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = TEST_NGINX_PORT,
    })

    function read_body(res)
        repeat
            local chunk, err = res.body_reader()
            if chunk then
                ngx.print(chunk)
            end
        until not chunk
    end
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local res, err = require("ledge.response").new()
        assert(not res, "new with empty args should return negatively")
        assert(string.find(err, "redis and key_chain args required"),
            "err should contain 'redis and key_chian args required'")

        local handler = require("ledge").create_handler()

        local res, err = require("ledge.response").new(
            handler.redis,
            handler:cache_key_chain()
        )

        assert(res and not err, "response object should be created without error")

        local ok, err = pcall(function()
            res.foo = "bar"
        end)
        assert(not ok, "setting unknown field should error")
        assert(string.find(err, "attempt to create new field foo"),
            "err should be 'attempt to create new field foo'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 2: set_body
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        local res, err = require("ledge.response").new(
            handler.redis,
            handler:cache_key_chain()
        )

        read_body(res) -- will be empty

        res:set_body("foo")

        read_body(res) -- will print foo
    }
}
--- request
GET /t
--- response_body: foo
--- no_error_log
[error]


=== TEST 3: filter_body_reader
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        local res, err = require("ledge.response").new(
            handler.redis,
            handler:cache_key_chain()
        )

        res:set_body("foo")

        -- turns foo to moo
        function get_cow_filter(reader)
            return coroutine.wrap(function()
                repeat
                    local chunk, err = reader()
                    if chunk then
                        coroutine.yield(ngx.re.gsub(chunk, "f", "m"))
                    end
                    
                until not chunk
            end)
        end
        
        -- turns moo to boo
        function get_sad_filter(reader)
            return coroutine.wrap(function()
                repeat
                    local chunk, err = reader()
                    if chunk then
                        coroutine.yield(ngx.re.gsub(chunk, "m", "b"))
                    end
                    
                until not chunk
            end)
        end

        res:filter_body_reader("cow", get_cow_filter(res.body_reader))
        res:filter_body_reader("sad", get_sad_filter(res.body_reader))

        read_body(res)
    }
}
--- request
GET /t
--- response_body: boo
--- no_error_log
[error]
