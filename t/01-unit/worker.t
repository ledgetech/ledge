use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

our $HttpConfig_Test6 = LedgeEnv::http_config(extra_lua_config => qq{
    foo = 1
    package.loaded["ledge.job.test"] = {
        perform = function(job)
            foo = foo + 1
            return true
        end
    }
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Load module without errors.
--- http_config eval: $::HttpConfig
--- config
location /worker_1 {
    echo "OK";
}
--- request
GET /worker_1
--- no_error_log
[error]


=== TEST 2: Create worker with default config
--- http_config eval: $::HttpConfig
--- config
location /worker_2 {
    echo "OK";
}
--- request
GET /worker_2
--- no_error_log
[error]


=== TEST 4: Create worker with bad config key
--- http_config eval
qq {
lua_package_path "./lib/?.lua;;";
init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
}
init_worker_by_lua_block {
    require("ledge.worker").new({
        foo = "one",
    })
}
}
--- config
location /worker_4 {
    echo "OK";
}
--- request
GET /worker_4
--- error_log
field foo does not exist


=== TEST 5: Run workers without errors
--- http_config eval
qq {
lua_package_path "./lib/?.lua;;";
init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end
}
init_worker_by_lua_block {
    require("ledge.worker").new():run()
}
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
--- http_config eval: $::HttpConfig_Test6
--- config
location /worker_6 {
    content_by_lua_block {
        local qless = assert(require("resty.qless").new({
            get_redis_client = require("ledge").create_qless_connection
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
