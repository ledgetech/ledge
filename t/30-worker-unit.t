use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2) + 1;

my $pwd = cwd();

#$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
#$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';
$ENV{TEST_COVERAGE} ||= 0;

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load module without errors.
--- http_config
lua_package_path "./lib/?.lua;;";
init_worker_by_lua_block {
    assert(require("ledge.worker").new())
}
--- config
location /worker_1 {
    echo "OK";
}
--- request
GET /worker_1
--- no_error_log
[error]


=== TEST 2: Create worker with default config
--- http_config
lua_package_path "./lib/?.lua;;";
init_worker_by_lua_block {
    assert(require("ledge.worker").new())
}
--- config
location /worker_2 {
    echo "OK";
}
--- request
GET /worker_2
--- no_error_log
[error]


=== TEST 3: Create worker with bad config value
--- http_config
lua_package_path "./lib/?.lua;;";
init_worker_by_lua_block {
    require("ledge.worker").new({
        interval = "one",
    })
}
--- config
location /worker_3 {
    echo "OK";
}
--- request
GET /worker_3
--- error_log
invalid config item or value type: interval


=== TEST 4: Create worker with bad config key
--- http_config
lua_package_path "./lib/?.lua;;";
init_worker_by_lua_block {
    require("ledge.worker").new({
        foo = "one",
    })
}
--- config
location /worker_4 {
    echo "OK";
}
--- request
GET /worker_4
--- error_log
invalid config item or value type: foo


=== TEST 5: Run workers without errors
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";
init_worker_by_lua_block {
    require("ledge.worker").new():run()
}
--- config
location /worker_5 {
    echo "OK";
}
--- request
GET /worker_5
--- no_error_log
[error]


=== TEST 6: Push a job and confirm it runs
--- http_config
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;;";
init_by_lua_block {
    foo = 1

    package.loaded["ledge.job.test"] = {
        perform = function(job)
            foo = foo + 1
            return true
        end
    }
}
init_worker_by_lua_block {
    require("ledge.worker").new():run()
}
--- config
location /worker_6 {
    content_by_lua_block {
        local qless = assert(require("resty.qless").new({
            connector = require("ledge").create_qless_connection
        }))

        local jid = assert(qless.queues["ledge_gc"]:put("ledge.job.test"))

        ngx.sleep(2)
        ngx.say(foo)
        local job = qless.jobs:get(jid)
        ngx.say(job.state)
    }
}
--- request
GET /worker_6
--- response_body
2
complete
--- timeout: 5
--- no_error_log
[error]
