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
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Bind and emit
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        local ok, err = handler:bind("non_event", function(arg) end)
        assert(not ok and err == "no such event: non_event",
            "err should be set")

        local function say(arg) ngx.say(arg) end

        local ok, err = handler:bind("after_cache_read", say)
        assert(ok and not err, "bind should return positively")

        local ok, err = pcall(handler.emit, handler, "non_event")
        assert(not ok and err == "attempt to emit non existent event: non_event",
            "emit should fail with non-event")

        -- Bind and emit all events
        handler:bind("before_upstream_request", say)
        handler:bind("after_upstream_request", say)
        handler:bind("before_save", say)
        handler:bind("before_save_revalidation_data", say)
        handler:bind("before_serve", say)
        handler:bind("before_esi_include_request", say)

        handler:emit("after_cache_read", "after_cache_read")
        handler:emit("before_upstream_request", "before_upstream_request")
        handler:emit("after_upstream_request", "after_upstream_request")
        handler:emit("before_save", "before_save")
        handler:emit("before_save_revalidation_data", "before_save_revalidation_data")
        handler:emit("before_serve", "before_serve")
        handler:emit("before_esi_include_request", "before_esi_include_request")
    }
}

--- request
GET /t
--- response_body
after_cache_read
before_upstream_request
after_upstream_request
before_save
before_save_revalidation_data
before_serve
before_esi_include_request
--- error_log
no such event: non_event


=== TEST 2: Bind multiple functions to an event
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()

        for i = 1, 3 do
            handler:bind("after_cache_read", function()
                ngx.say("function ", i)
            end)
        end

        handler:emit("after_cache_read")
    }
}
--- request
GET /t
--- response_body
function 1
function 2
function 3
--- no_error_log
[error]


=== TEST 3: Default binds
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    require("ledge").bind("after_cache_read", function(arg)
        ngx.say("default 1: ", arg)
    end)

    require("ledge").bind("after_cache_read", function(arg)
        ngx.say("default 2: ", arg)
    end)
}
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge = require("ledge")
        local ok, err = pcall(ledge.bind, "after_cache_read", function(arg)
            ngx.say(arg)
        end)

        assert(not ok and string.find(err, "attempt to call bind outside the 'init' phase"), err)

        local handler = require("ledge").create_handler()

        handler:bind("after_cache_read", function(arg)
            ngx.say("instance 1: ", arg)
        end)

        handler:bind("after_cache_read", function(arg)
            ngx.say("instance 2: ", arg)
        end)

        handler:emit("after_cache_read", "foo")
    }
}
--- request
GET /t
--- response_body
default 1: foo
default 2: foo
instance 1: foo
instance 2: foo
--- no_error_log
[error]
