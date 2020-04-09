use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config("", qq{
    TEST_NGINX_PORT = $LedgeEnv::nginx_port
});

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: string.randomhex
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local randomhex = require("ledge.util").string.randomhex

        -- lengths
        assert(#randomhex(10) == 10, "randomhex(10) length should be 10")
        assert(#randomhex(42) == 42, "randomhex(42) length should be 42")

        -- apparent randomness
        assert(randomhex(10) ~= randomhex(10),
            "random hex strings should differ")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 2: mt.fixed_field_metatable
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local fixed_field_metatable =
            require("ledge.util").mt.fixed_field_metatable

        -- Error if new field creation attempted
        local t = setmetatable({ a = 1, c = 3 }, fixed_field_metatable)
        local ok, err = pcall(
            function() t.b = 2 end,
            "attempt to create new field b"
        )
        assert(string.find(err,  "attempt to create new field b"),
            "err should contain 'attempt to create new field b'")

        -- Error if non existent field dereferenced
        local t = setmetatable({ a = 1, c = 3 }, fixed_field_metatable)
        local ok, err = pcall(
            function() local a = t.b end,
            "attempt to create new field b"
        )
        assert(string.find(err, "field b does not exist"),
            "err should contain 'field b does not exist'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 3: mt.get_fixed_field_metatable_proxy
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local get_fixed_field_metatable_proxy =
            require("ledge.util").mt.get_fixed_field_metatable_proxy

        local defaults = { a = 1, b = 2, c = 3 }

        -- Error if new field creation attempted
        local t = setmetatable(
            { b = 4 },
            get_fixed_field_metatable_proxy(defaults)
        )

        assert(t.a == 1, "t.a should be 1")
        assert(t.b == 4, "t.b should be 4")
        assert(t.c == 3, "t.c should be 3")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 4: mt.get_callable_fixed_field_metatable
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local get_callable_fixed_field_metatable =
            require("ledge.util").mt.get_callable_fixed_field_metatable

        local func =
            function(t, field)
                return t[field]
            end

        -- Error if new field creation attempted
        local t = setmetatable(
            { a = 1, b = 2, c = 3 },
            get_callable_fixed_field_metatable(func)
        )

        assert(t("a") == 1, "t('a') should return 1")
        assert(t("b") == 2, "t('b') should return 2")
        assert(t("c") == 3, "t('c') should return 3")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 5: table.copy
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tbl_copy = require("ledge.util").table.copy

        local mt = { __index = function(t, k) return "no index" end }
        local t = {
            a = 1,
            b = 2,
            c = {
                x = 10,
                y = 11,
                z = setmetatable({ 1, 2, 3 }, mt),
            }
        }

        local copy = tbl_copy(t)

        -- Values copied
        assert(t ~= copy, "copy should not equal t")
        assert(copy.a == 1, "copy.a should be 1")
        assert(type(copy.c) == "table", "copy.c should be a table")
        assert(copy.c ~= t.c, "copy.c should not equal t.c")
        assert(copy.c.x == 10, "copy.c.x should be 10")
        assert(type(copy.c.z) == "table", "copy.c.z should be a table")
        assert(copy.c.z ~= t.c.z, "copy.z.a. should not equal t.c.z")
        assert(copy.c.z[1] == 1, "copy.c.z[1] should be 1")
        assert(copy.c.z[3] == 3, "copy.c.z[3] should be 3")

        -- Metatables copied
        assert(getmetatable(copy) == nil, "getmetatable(copy) should be nil")
        assert(getmetatable(copy.c.z) ~= getmetatable(t.c.z),
            "copy.c.z metatable should not equal t.c.z metatable")
        assert(getmetatable(copy.c.z).__index == getmetatable(t.c.z).__index,
            "copy.c.z __index metamethod should equal t.c.z __index metamethod")
        assert(copy.c.z[4] == "no index", "copy.c.z[3] should be 'no index'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 6: table.copy_merge_defaults
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tbl_copy_merge_defaults =
            require("ledge.util").table.copy_merge_defaults
        local fixed_field_metatable =
            require("ledge.util").mt.fixed_field_metatable

        local defaults = {
            a = 1,
            c = 3,
            d = {
                x = 10,
                z = 12,
            },
            e = {
                a = 1,
                c = 3,
            },
        }

        local t = {
            a = false,
            b = 2,
            e = {
                b = 2,
            },
        }

        local copy = tbl_copy_merge_defaults(t, defaults)

        -- Basic copy merge
        assert(copy ~= t, "copy should not equal t")
        assert(getmetatable(copy) == nil, "copy should not have a metatable")
        assert(copy.a == false, "copy.a should be false")
        assert(copy.b == 2, "copy.b should be 2")
        assert(copy.c == 3, "copy.c should be 3")

        -- Child table in defaults is merged
        assert(copy.d ~= defaults.d, "copy.d should not equal defaults d")
        assert(copy.d.x == 10, "copy.d.x should be 10")
        assert(copy.d.z == 12, "copy.d.z should be 12")

        -- Child table in both is merged
        assert(copy.e ~= defaults.e, "copy.e should not equal defaults e")
        assert(copy.e.a == 1, "copy.e.a should be 1")
        assert(copy.e.b == 2, "copy.e.b should be 2")
        assert(copy.e.c == 3, "copy.e.c should be 3")


        -- Same again, but with defaults being "fixed field"
        local defaults = setmetatable({
            a = 1,
            b = 2,
            c = 3,
            d = setmetatable({
                x = 10,
                y = 11,
                z = 12,
            }, fixed_field_metatable)
        }, fixed_field_metatable)

        local t_good = {
            b = 6,
            d = {
                z = 42,
            },
        }

        -- Copy is merged properly
        local copy = tbl_copy_merge_defaults(t_good, defaults)

        assert(copy.a == 1, "copy.a should be 1")
        assert(copy.b == 6, "copy.b should be 6")
        assert(copy.c == 3, "copy.c should be 3")
        assert(copy.d ~= defaults.d and copy.d ~= t_good.d,
            "copy.d should not equal defaults.d or t_good.d")
        assert(getmetatable(copy) == nil, "getmetatable(copy) should be nil")


        -- Copy merge should fail
        local t_bad_1 = {
            a = 4,
            foo = "bar",
        }

        local ok, err = pcall(function()
            tbl_copy_merge_defaults(t_bad_1, defaults)
        end)

        assert(string.find(err, "field foo does not exist"),
            "error 'field foo does not exist' should be thrown")


        -- Copy merge should fail on inner table
        local t_bad_2 = {
            a = 4,
            d = {
                x = 10,
                foo = "bar",
            },
        }

        local ok, err = pcall(function()
            tbl_copy_merge_defaults(t_bad_1, defaults)
        end)

        assert(string.find(err, "field foo does not exist"),
            "error 'field foo does not exist' should be thrown")


        -- Copy merge with a nil user table gives us a copy of defaults
        local t, err = tbl_copy_merge_defaults(nil, defaults)

        assert(t ~= nil and t.a == 1,
            "merging a nil user table should still return defaults")
        assert(t ~= defaults, "defaults should be copied by value")


        local t, err = tbl_copy_merge_defaults(t_good, nil)
        assert(t ~= nil and t.b == 6,
            "merging with nil defaults should still return user t")
        assert(t ~= t_good, "user t should be copied by value")

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 7: string.split
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local str_split = require("ledge.util").string.split

        local str1 = "comma, separated, string, "
        local t = str_split(str1, ",")

        assert(#t == 4, "#t should be 4")
        assert(t[1] == "comma", "t[1] should be 'comma'")
        assert(t[2] == " separated", "t[2] should be ' separated'")
        assert(t[3] == " string", "t[3] should be ' string'")
        assert(t[4] == " ", "t[4] should be ' '")

        local t = str_split(str1, ", ")
        assert(#t == 3, "#t should be 3")
        assert(t[1] == "comma", "t[1] should be 'comma'")
        assert(t[2] == "separated", "t[2] should be ' separated'")
        assert(t[3] == "string", "t[3] should be ' string'")
    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 8: coroutine.wrap
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local co_wrap = require("ledge.util").coroutine.wrap

        local co = co_wrap(
            function()
                for i = 1, 10 do
                    coroutine.yield(i)
                end
            end
        )

        function run()
            local res = ""
            repeat
                local num = co()
                if num then
                    res = res .. num .. "-"
                end
            until not num
            res = res .. "finished"
            return res
        end

        assert(run() == "1-2-3-4-5-6-7-8-9-10-finished",
            "run() should return 1-2-3-4-5-6-7-8-9-10-finished")
    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 8b: coroutine.wrap errors
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local co_wrap = require("ledge.util").coroutine.wrap

        local co = co_wrap(
            function()
                for i = 1, 10 do
                    if i == 5 then
                        error("BOOM")
                    end
                    coroutine.yield(i)
                end
            end
        )

        function run()
            local res = ""
            repeat
                local num, err = co()
                if num then
                    res = res .. num .. "-"
                elseif err then
                    ngx.log(ngx.DEBUG, "Coroutine error: ", err)
                end
            until not num
            res = res .. "finished"
            return res
        end

        assert(run() == "1-2-3-4-finished", "Error was yielded!")
    }
}
--- request
GET /t
--- error_log
Coroutine error:
BOOM
--- no_error_log
Error was yielded!


=== TEST 9: get_hostname
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local get_hostname = require("ledge.util").get_hostname
        assert(string.lower(get_hostname()) == string.lower(ngx.var.hostname),
            "get_hostname "..tostring(get_hostname()).." should be "..ngx.var.hostname)
    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 10: append_server_port
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local append_server_port = require("ledge.util").append_server_port
        local host = "example.com"
        local default = host..":"..TEST_NGINX_PORT
        assert(append_server_port(host) == default,
            "append_server_port should be "..default)
    }
}
--- request
GET /t
--- no_error_log
[error]
