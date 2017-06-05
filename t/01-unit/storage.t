use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;;";


init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    -- Define storage backends here, and add requests to each test
    -- with backend=<backend> params.
    backends = {
        redis = {
            module = "ledge.storage.redis",
            params = {
                redis_connector = {
                    db = $ENV{TEST_LEDGE_REDIS_DATABASE},
                },
            },
        },
    }


    -- Utility returning an iterator over given chunked data
    function get_source(data)
        local index = 0
        return function()
            index = index + 1
            if data[index] then
                return data[index][1], data[index][2], data[index][3]
            end
        end
    end


    -- Utility returning an iterator over given chunked data, but which
    -- fails (simulating connection failure) at fail_pos iteration.
    function get_and_fail_source(data, fail_pos, storage)
        local index = 0
        return function()
            index = index + 1

            if index == fail_pos then
                storage.redis:close()
            end

            if data[index] then
                return data[index][1], data[index][2], data[index][3]
            end
        end
    end


    -- Utility to read the body as is serving
    function sink(iterator)
        repeat
            local chunk, err, has_esi = iterator()
            if chunk then
                ngx.say(chunk, ":", err, ":", tostring(has_esi))
            end
        until not chunk
    end


    -- Utilitu to report success and the size written
    function success_handler(bytes_written)
        ngx.say("wrote ", bytes_written, " bytes")
    end


    -- Utility to report the onfailure event was called
    function failure_handler(reason)
        ngx.say(reason)
    end


    -- Response object stub
    _res = {}
    local _mt = { __index = _res }

    function _res.new(entity_id)
        return setmetatable({
            entity_id = entity_id,
            body_reader = function() return nil end,
        }, _mt)
    end
}

};

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Load connect and close without errors.
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]
            local storage = require(config.module).new()

            assert(storage:connect(config.params),
                "storage:connect should return positively")
            assert(storage:close(),
                "storage:close() should return positively")

            ngx.print(ngx.req.get_uri_args()["backend"], " OK")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["redis OK"]
--- no_error_log
[error]


=== TEST 2: Write entity, read it back
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)

            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00002")
            res.body_reader = get_source({
                { "CHUNK 1", nil, false },
                { "CHUNK 2", nil, true },
                { "CHUNK 3", nil, false },
            })

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            assert(storage:exists(res.entity_id),
                "entity should exist")

            -- Attach the reader, and run sink
            res.body_reader = storage:get_reader(res)
            sink(res.body_reader)

            assert(storage:close(),
                "storage:close should return positively")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["CHUNK 1:nil:false
CHUNK 2:nil:true
CHUNK 3:nil:false
wrote 21 bytes
CHUNK 1:nil:false
CHUNK 2:nil:true
CHUNK 3:nil:false
"]
--- no_error_log
[error]


=== TEST 3: Fail to write entity larger than max_size
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)
            config.params.max_size = 8

            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00003")
            res.body_reader = get_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, false },
            })

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            -- Prove entity wasn't written
            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            assert(storage:close(),
                "storage:close should return positively")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:false
body is larger than 8 bytes
"]
--- no_error_log
[error]


=== TEST 4: Test zero length bodies are not written
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)
            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00004")

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            -- Prove entity wasn't written
            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            assert(storage:close(),
                "storage:close should return positively")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["wrote 0 bytes
"]
--- no_error_log
[error]


=== TEST 5: Test write fails and abort handler called if conn is interrupted
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        lua_socket_log_errors off;
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)
            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00005")
            -- Load source but fail on second chunk
            res.body_reader = get_and_fail_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, true },
            }, 2, storage)

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            -- Prove entity wasn't written (rolled back)
            assert(not storage:exists(res.entity_id),
                "entity should not exist")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:true
error writing: closed
"]
--- no_error_log
[error]


=== TEST 6: Write entity with short exiry, test keys expire
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)

            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00006")
            res.body_reader = get_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, false },
            })

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 1,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            assert(storage:exists(res.entity_id),
                "entity should exist")

            ngx.sleep(1)

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            assert(storage:close(),
                "storage:close should return positively")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:false
wrote 9 bytes
"]
--- no_error_log
[error]


=== TEST 7: Test maxmem keys are cleaned up when transactions are not available
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)

            config.params.max_size = 8

            -- Turn off atomicity
            config.params.supports_transactions = false
            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00007")
            -- Load source but fail on second chunk
            res.body_reader = get_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, true },
            }, storage)

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            -- Prove entity wasn't written (rolled back)
            assert(not storage:exists(res.entity_id),
                "entity should not exist")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:true
body is larger than 8 bytes
"]
--- no_error_log
[error]


=== TEST 8: Keys will remain on failure when transactions are not available
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        lua_socket_log_errors off;
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)

            config.params.supports_transactions = false
            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00008")
            -- Load source but fail on second chunk
            res.body_reader = get_and_fail_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, true },
            }, 2, storage)

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            -- Reconnect
            assert(storage:connect(config.params),
                "storage:connect should return positively")

            -- Prove it still exists (could not be cleaned up)
            assert(storage:exists(res.entity_id),
                "entity should exist")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:true
error writing: closed
"]
--- error_log eval
["closed"]


=== TEST 9: Close connection and then reconnect and re-read
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]

            -- This flag is required for has_esi flags to be read
            local ctx = {
                esi_process_enabled = true
            }

            local storage = require(config.module).new(ctx)

            assert(storage:connect(config.params),
                "storage:connect should return positively")

            local res = _res.new("00009")
            res.body_reader = get_source({
                { "123", nil, false },
                { "456", nil, true },
                { "789", nil, false },
            })

            assert(not storage:exists(res.entity_id),
                "entity should not exist")

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(
                res, 60,
                success_handler,
                failure_handler
            )
            sink(res.body_reader)

            assert(storage:exists(res.entity_id),
                "entity should exist")

            assert(storage:close(),
                "storage:close should return positively")

            assert(storage:connect(config.params),
                "storage:connect should return positively")

            assert(storage:exists(res.entity_id),
                "entity should exist")

            res.body_reader = storage:get_reader(res)
            sink(res.body_reader)

            assert(storage:close(),
                "storage:close should return positively")
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["123:nil:false
456:nil:true
789:nil:false
wrote 9 bytes
123:nil:false
456:nil:true
789:nil:false
"]
--- no_error_log
[error]
