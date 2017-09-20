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

    require("ledge.state_machine").set_debug(true)
}

}; # HttpConfig

no_long_string();
no_diff();
run_tests();


__DATA__
=== TEST 1: Root key is the same with nil ngx.var.args and empty string
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local key1 = ledge_cache_key.generate_root_key(nil, nil)

        ngx.req.set_uri_args({})

        local key2 = ledge_cache_key.generate_root_key(nil, nil)

        assert(key1 == key2, "key1 should equal key2")
    }
}

--- request
GET /t
--- no_error_log
[error]


=== TEST 2: Custom key spec
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local root_key = ledge_cache_key.generate_root_key(nil, nil)

        assert(root_key == "ledge:cache:http:localhost:/t:a=1",
            "root_key should be ledge:cache:http:localhost:/t:a=1")

        local cache_key_spec = {
                "scheme",
                "host",
                "port",
                "uri",
                "args",
            }
        local root_key = ledge_cache_key.generate_root_key(cache_key_spec, nil)

        assert(root_key == "ledge:cache:http:localhost:1984:/t:a=1",
            "root_key should be ledge:cache:http:localhost:1984:/t:a=1")

        local cache_key_spec = {
                "host",
                "uri",
            }
       local root_key = ledge_cache_key.generate_root_key(cache_key_spec, nil)

        assert(root_key == "ledge:cache:localhost:/t",
            "root_key should be ledge:cache:localhost:/t")


        local cache_key_spec = {
                "host",
                "uri",
                function() return "hello" end,
            }
        local root_key = ledge_cache_key.generate_root_key(cache_key_spec, nil)

        assert(root_key == "ledge:cache:localhost:/t:hello",
            "root_key should be ledge:cache:localhost:/t:hello")
    }
}

--- request
GET /t?a=1
--- no_error_log
[error]


=== TEST 3: Errors in cache key spec functions
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local cache_key_spec = {
                "host",
                "uri",
                function() return 123 end,
            }
        local root_key = ledge_cache_key.generate_root_key(cache_key_spec, nil)

        assert(root_key == "ledge:cache:localhost:/t",
            "cache_key should be ledge:cache:localhost:/t")


        local cache_key_spec = {
                "host",
                "uri",
                function() return foo() end,
            }
        local root_key = ledge_cache_key.generate_root_key(cache_key_spec, nil)

        assert(root_key == "ledge:cache:localhost:/t",
            "cache_key should be ledge:cache:localhost:/t")
    }
}

--- request
GET /t?a=2
--- error_log
functions supplied to cache_key_spec must return a string
error in function supplied to cache_key_spec


=== TEST 4: URI args are sorted (normalised)
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local root_key = ledge_cache_key.generate_root_key(nil, nil)
        ngx.print(root_key)
    }
}
--- request eval
[
    "GET /t",
    "GET /t?a=1",
    "GET /t?aba=1&aab=2",
    "GET /t?a=1&b=2&c=3",
    "GET /t?b=2&a=1&c=3",
    "GET /t?c=3&a=1&b=2",
    "GET /t?c=3&b&a=1",
    "GET /t?c=3&b=&a=1",
    "GET /t?c=3&b=2&a=1&b=4",
]
--- response_body eval
[
    "ledge:cache:http:localhost:/t:",
    "ledge:cache:http:localhost:/t:a=1",
    "ledge:cache:http:localhost:/t:aab=2&aba=1",
    "ledge:cache:http:localhost:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:/t:a=1&b=2&c=3",
    "ledge:cache:http:localhost:/t:a=1&b&c=3",
    "ledge:cache:http:localhost:/t:a=1&b=&c=3",
    "ledge:cache:http:localhost:/t:a=1&b=2&b=4&c=3",
]
--- no_error_log
[error]


=== TEST 5: Max URI args
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local root_key = ledge_cache_key.generate_root_key(nil, 2)
        ngx.print(root_key)
    }
}
--- request eval
[
    "GET /t",
    "GET /t?a=1",
    "GET /t?b=2&a=1",
    "GET /t?c=3&b=2&a=1",
]
--- response_body eval
[
    "ledge:cache:http:localhost:/t:",
    "ledge:cache:http:localhost:/t:a=1",
    "ledge:cache:http:localhost:/t:a=1&b=2",
    "ledge:cache:http:localhost:/t:b=2&c=3",
]
--- no_error_log
[error]


=== TEST 6: Wildcard purge URIs
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local ledge_cache_key = require("ledge.cache_key")

        local root_key = ledge_cache_key.generate_root_key(nil, nil)
        ngx.print(root_key)
    }
}
--- request eval
[
    "PURGE /t*",
    "PURGE /t?*",
    "PURGE /t?a=1*",
    "PURGE /t?a=*",
]
--- response_body eval
[
    "ledge:cache:http:localhost:/t*:*",
    "ledge:cache:http:localhost:/t:*",
    "ledge:cache:http:localhost:/t:a=1*",
    "ledge:cache:http:localhost:/t:a=*",
]
--- no_error_log
[error]

=== TEST 7: Compare vary spec
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local vary_spec_compare = require("ledge.cache_key").vary_spec_compare

        -- Compare vary specs
        local changed = vary_spec_compare({}, {})
        assert(changed == false, "empty table == empty table")

        local changed = vary_spec_compare({}, nil)
        assert(changed == false, "empty table == nil")

        local changed = vary_spec_compare(nil, {})
        assert(changed == false, "nil == empty table")

        local changed = vary_spec_compare({"Foo"}, {"Foo"})
        assert(changed == false, "table == table")

        local changed = vary_spec_compare({"Foo", "Bar"}, {"Foo", "Bar"})
        assert(changed == false, "table == table (multi-values")


        local changed = vary_spec_compare({"Foo"}, {})
        assert(changed == true, "table ~= empty table")

        local changed = vary_spec_compare({}, {"Foo"})
        assert(changed == true, "empty table ~= table")

        local changed = vary_spec_compare({"Foo"}, nil)
        assert(changed == true, "table ~= nil")

        local changed = vary_spec_compare(nil, {"Foo"})
        assert(changed == true, "nil  ~= table")

        local changed = vary_spec_compare({"Foo"}, {})
        assert(changed == true, "table ~= empty table")
    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 8: Generate vary key
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local function log(...)
            ngx.log(ngx.DEBUG, ...)
        end

        local generate_vary_key = require("ledge.cache_key").generate_vary_key

        local called_flag = false
        local callback = function(vary_key)
            assert(type(vary_key) == "table", "callback receives vary key_table")
            called_flag = true
        end


        -- Set headers
        ngx.req.set_header("Foo", "Bar")
        ngx.req.set_header("X-Test", "value")

        called_flag = false

        -- Empty/nil spec
        local vary_key = generate_vary_key(nil, nil, nil)
        log(vary_key)
        assert(vary_key == "", "Nil spec generates empty string")

        local vary_key = generate_vary_key({}, nil, nil)
        log(vary_key)
        assert(vary_key == "", "Empty spec generates empty string")

        local vary_key = generate_vary_key(nil, callback, nil)
        log(vary_key)
        assert(called_flag == true, "Callback is called with nil spec")
        assert(vary_key == "", "Nil vary spec not modified with noop function")
        called_flag = false

        local vary_key = generate_vary_key({}, callback, nil)
        log(vary_key)
        assert(called_flag == true, "Callback is called with empty spec")
        assert(vary_key == "", "Empty vary spec not modified with noop function")
        called_flag = false


        -- With spec
        local vary_key = generate_vary_key({"Foo"}, callback, nil)
        log(vary_key)
        assert(called_flag == true, "Callback is called")
        assert(vary_key == "Foo:Bar", "Vary spec not modified with noop function")
        called_flag = false

        local vary_key = generate_vary_key({"Foo", "X-Test"}, callback, nil)
        log(vary_key)
        assert(called_flag == true, "Callback is called - multivalue spec")
        assert(vary_key == "Foo:Bar:X-Test:value", "Vary spec not modified with noop function - multivalue spec")
        called_flag = false


        -- Active callback
        callback = function(vary_key)
            vary_key["MyVal"] = "Arbitrary"
        end
        local vary_key = generate_vary_key(nil, callback, nil)
        log(vary_key)
        assert(vary_key == "MyVal:Arbitrary", "Callback modifies key with nil spec")

        local vary_key = generate_vary_key({}, callback, nil)
        log(vary_key)
        assert(vary_key == "MyVal:Arbitrary", "Callback modifies key with empty spec")

        local vary_key = generate_vary_key({"Foo"}, callback, nil)
        log(vary_key)
        assert(vary_key == "Foo:Bar:MyVal:Arbitrary", "Callback appends key with spec")

        local vary_key = generate_vary_key({"Foo", "X-Test"}, callback, nil)
        log(vary_key)
        assert(vary_key == "MyVal:Arbitrary:Foo:Bar:X-Test:value", "Callback appends key with spec - multi values")


        callback = function(vary_key)
            vary_key["Foo"] = "Arbitrary"
        end

        local vary_key = generate_vary_key({"Foo"}, callback, nil)
        log(vary_key)
        assert(vary_key == "Foo:Arbitrary", "Callback overrides key spec")


        callback = function(vary_key)
            vary_key["Foo"] = nil
        end

        local vary_key = generate_vary_key({"Foo"}, callback, nil)
        log(vary_key)
        assert(vary_key == "", "Callback removes from key spec")


        callback = function(vary_key)
            assert(vary_key["X-None"] == ngx.null, "Spec values with missing headers appear as null")
        end

        local vary_key = generate_vary_key({"X-None"}, callback, nil)
        log(vary_key)
        assert(vary_key == "", "Missing values do not appear in key")


        local vary_key = generate_vary_key({"A", "B"}, nil, {["A"] = "123", ["B"] = "xyz"})
        log(vary_key)
        assert(vary_key == "A:123:B:xyz", "Vary key from arbitrary headers")

        local vary_key = generate_vary_key({"Foo", "B"}, nil, {["Foo"] = "123", ["B"] = "xyz"})
        log(vary_key)
        assert(vary_key == "Foo:123:B:xyz", "Arbitrary headers take precendence")

    }
}
--- request
GET /t
--- no_error_log
[error]

=== TEST 9: Read vary spec
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local read_vary_spec = require("ledge.cache_key").read_vary_spec

        local root_key = "ledge:dummy:root:"
        local vary_spec_key = root_key.."::vary"

        local spec, err = read_vary_spec()
        assert(spec == nil and err ~= nil, "Redis required to read spec")

        local spec, err = read_vary_spec(redis)
        assert(spec == nil and err ~= nil, "Root key required to read spec")

        redis.smembers = function() return nil, "Redis Error" end
        local spec, err = read_vary_spec(redis, root_key)
        assert(spec == nil and err == "Redis Error", "Redis error returned")
        redis.smembers = require("resty.redis").smembers


        local exists = redis:exists(vary_spec_key)
        local spec, err = read_vary_spec(redis, root_key)
        assert(type(spec) == "table" and #spec == 0 and exists == 0, "Missing key returns empty table")


        redis:sadd(vary_spec_key, "Foo")
        redis:sadd(vary_spec_key, "Bar")
        local spec, err = read_vary_spec(redis, root_key)
        assert(type(spec) == "table" and #spec == 2 and spec[1] == "Foo", "Spec returned")

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 10: Key chain
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local key_chain = require("ledge.cache_key").key_chain

        local root_key = "ledge:dummy:root:"
        local vary_key = "Foo:Bar:Test:value"
        local vary_spec = {"Foo", "Test"}

        local expected = {
            vary              = "ledge:dummy:root:::vary",
            repset            = "ledge:dummy:root:::repset",
            main              = "ledge:dummy:root:#Foo:Bar:Test:value::main",
            entities          = "ledge:dummy:root:#Foo:Bar:Test:value::entities",
            headers           = "ledge:dummy:root:#Foo:Bar:Test:value::headers",
            reval_params      = "ledge:dummy:root:#Foo:Bar:Test:value::reval_params",
            reval_req_headers = "ledge:dummy:root:#Foo:Bar:Test:value::reval_req_headers",
        }
        local extra = {
            root = "ledge:dummy:root:",
            full = "ledge:dummy:root:#Foo:Bar:Test:value",
            fetching_lock = "ledge:dummy:root:#Foo:Bar:Test:value::fetching",
        }

        local chain, err = key_chain()
        assert(chain == nil and err ~= nil, "Root key required")

        local chain, err = key_chain(root_key)
        assert(chain == nil and err ~= nil, "Vary key required")

        local chain, err = key_chain(root_key, vary_key)
        assert(chain == nil and err ~= nil, "Vary spec required")


        local chain, err = key_chain(root_key, vary_key, vary_spec)
        assert(type(chain) == "table", "key chain returned")

        local i = 0
        for k,v in pairs(chain) do
            i = i +1
            ngx.log(ngx.DEBUG, k, ": ", v, " == ", expected[k])
            assert(expected[k] == v, k.." chain mismatch")
        end
        assert(i == 7, "7 keys: "..i)

        for k,v in pairs(expected) do
            ngx.log(ngx.DEBUG, k,": ", v, " == ", chain[k])
            assert(chain[k] == v, k.." expected mismatch")
        end

        for k,v in pairs(extra) do
            ngx.log(ngx.DEBUG, k,": ", v, " == ", chain[k])
            assert(chain[k] == v, k.." extra mismatch")
        end

        for i,v in ipairs(vary_spec) do
            assert(chain.vary_spec[i] == v, " Vary spec mismatch")
        end

    }
}
--- request
GET /t
--- no_error_log
[error]


=== TEST 11: Save key chain
--- http_config eval: $::HttpConfig
--- config
location /t {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local key_chain = require("ledge.cache_key").key_chain
        local save_key_chain = require("ledge.cache_key").save_key_chain

        local root_key = "ledge:dummy:root:"
        local vary_key = "Foo:Bar:Test:value"
        local vary_spec = {"Foo", "Test"}


        local chain = key_chain(root_key, vary_key, vary_spec)

        local ok, err = save_key_chain()
        assert(ok == nil and err ~= nil, "Redis required")

        local ok, err = save_key_chain(redis)
        assert(ok == nil and err ~= nil, "Key chain required")

        local ok, err = save_key_chain(redis, "foo")
        assert(ok == nil and err ~= nil, "Key chain must be a table")

        local ok, err = save_key_chain(redis, {})
        assert(ok == nil and err ~= nil, "Key chain must not be empty")

        local ok, err = save_key_chain(redis, chain)
        assert(ok == nil and err ~= nil, "TTL required")

        local ok, err = save_key_chain(redis, chain, "foo")
        assert(ok == nil and err ~= nil, "TTL must be a number")


        -- Create main key
        redis:set(chain.main, "foobar")

        local ok, err = save_key_chain(redis, chain, 3600)
        assert(ok == true , "returns true")

        assert(redis:exists(chain.vary) == 1, "Vary spec key created")
        assert(redis:exists(chain.repset) == 1, "Repset created")

        local vs = redis:smembers(chain.vary)
        for i, v in pairs(vs) do
            assert(vary_spec[i] == v, "Vary spec saved: "..i)
        end

        local vs = redis:smembers(chain.repset)
        for _, v in pairs(vs) do
            assert(v == chain.full, "Full key added to repset")
        end

        assert(redis:ttl(chain.vary) == 3600, "Vary spec expiry set")
        assert(redis:ttl(chain.repset) == 3600, "Repset expiry set")

        local vary_spec = {"Baz", "Qux"}
        local chain = key_chain(root_key, vary_key, vary_spec)
        local ok, err = save_key_chain(redis, chain, 3600)

        local vs = redis:smembers(chain.vary)
        for i, v in pairs(vs) do
            assert(vary_spec[i] == v, "Vary spec overwritten: "..i)
        end

        redis:sadd(chain.repset, "dummy_value")
        local ok, err = save_key_chain(redis, chain, 3600)

        local vs = redis:smembers(chain.repset)
        for _, v in pairs(vs) do
            assert(v ~= "dummy_value", "Missing keys are removed from repset")
        end

        redis:del(chain.repset)

        local chain = key_chain(root_key, vary_key, {})
        local ok, err = save_key_chain(redis, chain, 3600)
        assert(redis:exists(chain.vary ) == 0, "Empty spec removes vary key")
        assert(redis:exists(chain.repset)  == 1, "Empty spec still creates repset")

    }
}
--- request
GET /t
--- no_error_log
[error]
