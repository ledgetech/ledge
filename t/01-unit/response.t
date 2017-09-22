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
        assert(err ~= nil, "err not nil")

        local res, err = require("ledge.response").new({})
        assert(not res, "new with empty handler should return negatively")
        assert(err ~= nil, "err not nil")

        local res, err = require("ledge.response").new({redis = {} })
        assert(not res, "new with empty handler redis should return negatively")
        assert(err ~= nil, "err not nil")

        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

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
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

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
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        require("ledge.response").set_debug(true)
        local res, err = require("ledge.response").new(handler)

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

        local ok, err = pcall(res.filter_body_reader, res, "bad", "foo")
        assert(not ok and string.find(err, "filter must be a function"),
            "error shoudl contain 'filter must be a function'")

        read_body(res)
    }
}
--- request
GET /t


=== TEST 4: is_cacheable
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        require("ledge.response").set_debug(true)
        local res, err = require("ledge.response").new(handler)

        assert(not res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60",
        }
        assert(res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60",
            ["Pragma"] = "no-cache",
        }
        assert(not res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "s-maxage=60, private",
        }
        assert(not res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60, no-store",
        }
        assert(not res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60, no-cache",
        }
        assert(not res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60, no-cache=X-Foo",
        }
        assert(res:is_cacheable())

        res.header = {
            ["Cache-Control"] = "max-age=60",
            ["Vary"] = "*",
        }
        assert(not res:is_cacheable())
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 5: ttl
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        require("ledge.response").set_debug(true)
        local res, err = require("ledge.response").new(handler)

        assert(res:ttl() == 0, "ttl should be 0")

        res.header = {
            ["Expires"] = ngx.http_time(ngx.time() + 10)
        }
        assert(res:ttl() == 10, "Expires was 10 seconds in the future")

        res.header["Cache-Control"] = "max-age=20"
        assert(res:ttl() == 20, "max-age overrides to 20 seconds")

        res.header["Cache-Control"] = "s-maxage=30"
        assert(res:ttl() == 30, "s-maxage overrides to 30 seconds")

        res.header["Cache-Control"] = "max-age=20, s-maxage=30"
        assert(res:ttl() == 30, "s-maxage still overrides to 30 seconds")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 6: save / read / set_and_save
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

        res.uri = "http://example.com"
        res.status = 200

        local ok, err = res:save(60)
        assert(ok and not err, "res should save without err")


        local res2, err = require("ledge.response").new(handler)

        local ok, err = res2:read()
        assert(ok and not err, "res2 should save without err")

        assert(res2.uri == "http://example.com", "res2 uri")

        res2.header["X-Save-Me"] = "ok"
        res2:save(60)

        local res3, err = require("ledge.response").new(handler)
        res3:read()

        assert(res3.header["X-Save-Me"] == "ok", "res3 headers")

        local ok, err = res3:set_and_save("size", 99)
        assert(ok and not err, "set_and_save should return positively")

        assert(res3.size == 99, "res3.size should be 99")

        local res4, err = require("ledge.response").new(handler)
        res4:read()

        assert(res4.size == 99, "res3.size should be 99")

        local ok, err = res4:set_and_save(nil, 2)
        assert(not ok and err, "set_and_save should fail with bad params")
    }
}
--- request
GET /t
--- error_log
set_and_save(): ERR wrong number of arguments for 'hset' command

=== TEST 7: read differentiates between redis failure and broken cache entry
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

        -- Ensure entry exists
        res.uri = "http://example.com"
        res.status = 200
        res.size = 1
        assert(res:save(60), "res should save without err")

        -- Break entities
        redis:del(handler:cache_key_chain().entities)

        local ok, err = res:read()
        assert(ok == nil and not err, "read should return no error with broken entities")


        -- Break headers
        redis:del( handler:cache_key_chain().headers)

        local ok, err = res:read()
        assert(ok == nil and not err, "read should return no error with broken headers")

        -- Missing main key
        redis:del( handler:cache_key_chain().main)

        local ok, err = res:read()
        assert(ok == nil and not err, "read should return no error  with missing main key")

        -- Break Redis instance
        res.redis.hgetall = function() return ngx.null end

        local ok, err = res:read()
        assert(ok or not err, "read should return error on redis error")
    }
}
--- request
GET /t
--- error_code: 200
--- no_error_log
[error]

=== TEST 8: save should replace the has_esi flag
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

        res.uri = "http://example.com"
        res.status = 200

        local ok, err = res:save(60)
        assert(ok and not err, "res should save without err")

        res:set_and_save("has_esi", "dummy")

        local res2, err = require("ledge.response").new(handler)

        local ok, err = res2:read()
        assert(ok and not err, "res2 should save without err")

        assert(res2.uri == "http://example.com", "res2 uri")
        assert(res2.has_esi == "dummy", "res2 has_esi")

        res2.header["X-Save-Me"] = "ok"
        res2:save(60)

        local res3, err = require("ledge.response").new(handler)
        res3:read()

        assert(res3.header["X-Save-Me"] == "ok", "res3 headers")
        assert(res3.has_esi == false, "res3 has_esi: "..tostring(res3.has_esi))

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 9: Process Vary
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local encode = require("cjson").encode
        local handler = require("ledge").create_handler()
        local redis = require("ledge").create_redis_connection()
        handler.redis = redis

        local res, err = require("ledge.response").new(handler)

        local tests = {
            {
                hdr = nil,
                res = nil,
                msg = "Nil header, nil spec",
            },
            {
                hdr = "",
                res = nil,
                msg = "Empty header, nil spec",
            },
            {
                hdr = "foo",
                res = {"foo"},
                msg = "Single field",
            },
            {
                hdr = "Foo",
                res = {"foo"},
                msg = "Single field - case",
            },
            {
                hdr = "fOo,bar,Baz",
                res = {"bar","baz","foo"},
                msg = "Multi field",
            },
            {
                hdr = "fOo, bar     ,       Baz",
                res = {"bar","baz","foo"},
                msg = "Multi field - whitespace",
            },
            {
                hdr = "bar,baz,foo",
                res = {"bar","baz","foo"},
                msg = "Multi field - sort1",
            },
                    {
                hdr = "foo,baz,bar",
                res = {"bar","baz","foo"},
                msg = "Multi field - sort2",
            },

            {
                hdr = "foo, bar, bar, foo, baz",
                res = {"bar","baz","foo"},
                msg = "De-duplicate",
            },
        }

        for _, t in ipairs(tests) do
            res.header["Vary"] = t["hdr"]
            local vary_spec = res:process_vary()
            ngx.log(ngx.DEBUG, "-----------------------------------------------")
            ngx.log(ngx.DEBUG, "header:   ", t["hdr"])
            ngx.log(ngx.DEBUG, "spec:     ", encode(vary_spec))
            ngx.log(ngx.DEBUG, "expected: ", encode(t["res"]))

            if type(t["res"]) == "table" then
                for i, v in ipairs(t["res"]) do
                    assert(vary_spec[i] == v, t["msg"])
                end
            else

                assert(res:process_vary() == t["res"], t["msg"])
            end

        end
    }
}
--- request
GET /t
--- no_error_log
[error]
