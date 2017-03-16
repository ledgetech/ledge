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
                return unpack(data[index])
            end
        end

        function sink(iterator)
            repeat
                local chunk, err, has_esi = iterator()
                if chunk then
                    ngx.print(chunk)
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

            local ok, err = storage:connect(config.params)
            if not ok then error(err) end

            local ok, err = storage:close()
            if not ok then error(err) end
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- no_error_log
[error]


=== TEST 2: Write entity, read it back
--- http_config eval: $::HttpConfig
--- config
    location /storage {
        content_by_lua_block {
            local config = backends[ngx.req.get_uri_args()["backend"]]
            local storage = require(config.module).new()

            local ok, err = storage:connect(config.params)
            if not ok then error(err) end

            local res = require("ledge.response").new()
            res.entity_id = "00001"
            res.body_reader = get_source({
                "asd", nil, false
            })

            if storage:exists(res.entity_id) then
                error("entity: ", res.entity_id, " already exists")
            else
                res.body_reader = storage:get_writer(res, 60, function() end)
                sink(res.body_reader)
            end

            local ok, err = storage:close()
            if not ok then error(err) end
        }
    }
--- request eval
["GET /storage?backend=redis"]
--- no_error_log
[error]
