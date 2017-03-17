use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3);

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

        backends = {
            redis = {
                module = "ledge.storage.redis",
                params = {
                    db = $ENV{TEST_LEDGE_REDIS_DATABASE},
                },
            },
        }

        function get_source(data)
            local index = 0
            return function()
                index = index + 1
                if data[index] then
                    return data[index][1], data[index][2], data[index][3]
                end
            end
        end

        function sink(iterator)
            repeat
                local chunk, err, has_esi = iterator()
                if chunk then
                    ngx.say(chunk, ":", err, ":", tostring(has_esi))
                end
            until not chunk
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

            assert(storage:connect(config.params))
            assert(storage:close())

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

            assert(storage:connect(config.params))

            -- Fake response object stub
            local res = {
                entity_id = "00001",
                body_reader = get_source({
                    { "CHUNK 1", nil, false },
                    { "CHUNK 2", nil, true },
                    { "CHUNK 3", nil, false },
                }),
                set_and_save = function(self, f, v)
                    ngx.say("saving ", f, " to ", v)
                end,
            }

            assert(not storage:exists(res.entity_id))

            -- Attach the writer, and run sink
            res.body_reader = storage:get_writer(res, 60)
            sink(res.body_reader)

            assert(storage:exists(res.entity_id))

            -- Attach the reader, and run sink
            res.body_reader = storage:get_reader(res)
            sink(res.body_reader)

            assert(storage:close())
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- response_body eval
["CHUNK 1:nil:false
CHUNK 2:nil:true
CHUNK 3:nil:false
saving size to 21
CHUNK 1:nil:false
CHUNK 2:nil:true
CHUNK 3:nil:false
"]
--- no_error_log
[error]
