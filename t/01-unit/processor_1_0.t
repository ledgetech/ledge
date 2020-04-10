use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = assert(require("ledge.esi.processor_1_0"),
            "module should load without errors")

        local processor = processor.new(require("ledge").create_handler())
        assert(processor, "processor_1_0.new should return positively")

        ngx.say("OK")
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
OK

=== TEST 2: esi_eval_var - QUERY STRING
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"QUERY_STRING", nil, "default", "default_quoted" },
            {"QUERY_STRING", nil, nil, "default_quoted" },
            {"QUERY_STRING", "test_param", "default", "default_quoted" },
            {"QUERY_STRING", "test_param", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?test_param=test",
  "GET /t?other_param=test",
  "GET /t?test_param=test&test_param=test2",
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
default
default_quoted
",

"test_param=test
test_param=test
test
test
",

"other_param=test
other_param=test
default
default_quoted
",

"test_param=test&test_param=test2
test_param=test&test_param=test2
test, test2
test, test2
",
]


=== TEST 3: esi_eval_var - HTTP header
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_X_TEST", nil, "default", "default_quoted" },
            {"HTTP_X_TEST", nil, nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"X-Dummy: foo",
"X-TEST: test_val"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
",

"test_val
test_val
",
]

=== TEST 4: esi_eval_var - Duplicate HTTP header
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_X_TEST", nil, "default", "default_quoted" },
            {"HTTP_X_TEST", nil, nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"X-Dummy: foo",

"X-TEST: test_val
X-TEST: test_val2"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
",

"test_val, test_val2
test_val, test_val2
",
]

=== TEST 5: esi_eval_var - Cookie
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_COOKIE", nil, "default", "default_quoted" },
            {"HTTP_COOKIE", "test_cookie", "default", "default_quoted" },
            {"HTTP_COOKIE", "test_cookie", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"",
"Cookie: none=here",
"Cookie: test_cookie=my_cookie"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"none=here
default
default_quoted
",

"test_cookie=my_cookie
my_cookie
my_cookie
",
]

=== TEST 6: esi_eval_var - Accept-Lang
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", nil, "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", "en", "default", "default_quoted" },
            {"HTTP_ACCEPT_LANGUAGE", "de", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t",
  "GET /t",
  "GET /t",
]
--- more_headers eval
[
"",

"Accept-Language: en-gb",

"Accept-Language: en-us, blah",

"Accept-Language: en-gb
Accept-Language: test"
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"en-gb
true
false
",

"en-us, blah
true
false
",

"en-gb, test
true
false
",
]

=== TEST 7: esi_eval_var - ESI_ARGS
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        -- Fake ESI args
        require("ledge.esi").filter_esi_args(
            require("ledge").create_handler()
        )
        ngx.log(ngx.DEBUG, require("cjson").encode(ngx.ctx.__ledge_esi_args))

        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"ESI_ARGS", nil, "default", "default_quoted" },
            {"ESI_ARGS", "var1", "default", "default_quoted" },
            {"ESI_ARGS", "var2", nil, "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?esi_var1=test1&esi_var2=test2&foo=bar",
  "GET /t?esi_var2=test2&foo=bar",
  "GET /t?esi_var1=test1&esi_other_var=foo&foo=bar",
  "GET /t?esi_var1=test1&esi_var1=test2&foo=bar",
]
--- no_error_log
[error]
--- response_body eval
[
"default
default
default_quoted
",

"esi_var2=test2&esi_var1=test1
test1
test2
",

"esi_var2=test2
default
test2
",

"esi_other_var=foo&esi_var1=test1
test1
default_quoted
",

"esi_var1=test1&esi_var1=test2
test1,test2
default_quoted
",
]

=== TEST 8: esi_eval_var - custom vars
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        ngx.ctx.__ledge_esi_custom_variables = ngx.req.get_uri_args() or {}

        if ngx.ctx.__ledge_esi_custom_variables["empty"] then
            ngx.ctx.__ledge_esi_custom_variables = {}
        else
            ngx.ctx.__ledge_esi_custom_variables["deep"] = {["table"] = "value!"}
        end

        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            --{"var_name", "key", "default", "default_quoted" },
            {"var1", nil, "default", "default_quoted" },
            {"var2", nil, nil, "default_quoted" },
            {"var1", "subvar", nil, "default_quoted" },
            {"deep", "table", "default", "default_quoted" },
        }
        for _,test in ipairs(tests) do
            ngx.say(processor.esi_eval_var(test))
        end
    }
}

--- request eval
[
  "GET /t",
  "GET /t?var1=test1&var2=test2",
  "GET /t?var2=test2",
  "GET /t?empty=true",
]
--- no_error_log
[error]
--- response_body eval
[
"default
default_quoted
default_quoted
value!
",

"test1
test2
default_quoted
value!
",

"default
test2
default_quoted
value!
",

"default
default_quoted
default_quoted
default
",
]

=== TEST 9: esi_process_vars_tag
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        ngx.ctx.__ledge_esi_custom_variables = {

            ["DANGER_ZONE"] = '<esi:include src="/kenny" />'
        }
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
        -- vars tags
            {
                ["chunk"] = [[<esi:vars>$(QUERY_STRING)</esi:vars>]],
                ["res"]   = [[test_param=test]],
                ["msg"]   = "vars tag"
            },
            {
                ["chunk"] = [[before <esi:vars>$(QUERY_STRING)</esi:vars> after]],
                ["res"]   = [[before test_param=test after]],
                ["msg"]   = "vars tag - outside content"
            },
            {
                ["chunk"] = [[before <esi:vars>$(QUERY_STRING) after</esi:vars>]],
                ["res"]   = [[before test_param=test after]],
                ["msg"]   = "vars tag - inside content"
            },
            {
                ["chunk"] = [[   <esi:vars>   $(QUERY_STRING{test_param})   </esi:vars>   ]],
                ["res"]   = [[      test      ]],
                ["msg"]   = "vars tag - whitespace"
            },
            {
                ["chunk"] = [[<esi:vars><h1>$(QUERY_STRING)</h1></esi:vars>]],
                ["res"]   = [[<h1>test_param=test</h1>]],
                ["msg"]   = "vars tag - html tags"
            },
            {
                ["chunk"] = [[<esi:vars></esi:vars>]],
                ["res"]   = [[]],
                ["msg"]   = "empty vars tags removed"
            },
            {
                ["chunk"] = [[<esi:vars><p>foo</p></esi:vars>]],
                ["res"]   = [[<p>foo</p>]],
                ["msg"]   = "empty vars tags removed - content preserved"
            },
        --  injecting ESI tags from vars
            {
                ["chunk"] = [[<esi:vars>$(DANGER_ZONE)</esi:vars>]],
                ["res"]   = [[&lt;esi:include src="/kenny" /&gt;]],
                ["msg"]   = "Injected tags are escaped"
            },
        }
        for _, t in pairs(tests) do
            local output = processor.esi_process_vars_tag(t["chunk"])
            ngx.log(ngx.DEBUG, "'", output, "'")
            assert(output == t["res"], "esi_process_vars_tag mismatch: "..t["msg"] )
        end
        ngx.say("OK")
    }
}
location /kenny {
    content_by_lua_block {
        ngx.print("Shouldn't see this")
    }
}

--- request
GET /t?test_param=test
--- no_error_log
[error]
--- response_body
OK


=== TEST 12: process_escaping
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local processor = require("ledge.esi.processor_1_0")
        local tests = {
            {
                ["chunk"] = [[Lorem ipsum dolor sit amet, consectetur adipiscing elit.]],
                ["res"]   = [[Lorem ipsum dolor sit amet, consectetur adipiscing elit.]],
                ["msg"]   = "nothing to escape"
            },
            {
                ["chunk"] = [[Lorem<!--esi ipsum dolor sit amet, -->consectetur adipiscing elit.]],
                ["res"]   = [[Lorem ipsum dolor sit amet, consectetur adipiscing elit.]],
                ["msg"]   = "no esi inside"
            },
            {
                ["chunk"] = [[Lorem<!--esi <esi:vars>$(QUERY_STRING)</esi:vars>ipsum dolor sit amet, -->consectetur adipiscing elit.]],
                ["res"]   = [[Lorem <esi:vars>$(QUERY_STRING)</esi:vars>ipsum dolor sit amet, consectetur adipiscing elit.]],
                ["msg"]   = "esi:vars inside"
            },

        }
        for _, t in pairs(tests) do
            local output = processor.process_escaping(t["chunk"])
            ngx.log(ngx.DEBUG, "'", output, "'")
            assert(output == t["res"], "process_escaping mismatch: "..t["msg"] )
        end
        ngx.say("OK")
    }
}

--- request
GET /t?test_param=test
--- no_error_log
[error]
--- response_body
OK

=== TEST 13: fetch include
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        -- Override the normal coroutine.yield function
        local output
        coroutine.yield = function(chunk) output = chunk end

        local processor = require("ledge.esi.processor_1_0")
        local handler = require("ledge").create_handler()
        local self = {
            handler = handler
        }
        local buffer_size = 64*1024
        local tests = {
            {
                ["tag"] = [[<esi:include src="/frag" />]],
                ["res"]   = [[fragment]],
                ["msg"]   = "nothing to escape"
            },
            {
                ["tag"] = [[<esi:include src="/frag?$(QUERY_STRING{test})" />]],
                ["res"]   = [[fragmentfoobar]],
                ["msg"]   = "Query string var is evaluated"
            },

        }
        for _, t in pairs(tests) do
            local ret = processor.esi_fetch_include(self, t["tag"], buffer_size)
            ngx.log(ngx.DEBUG, "RET: '", ret, "'")
            ngx.log(ngx.DEBUG, "OUTPUT: '", output, "'")
            assert(output == t["res"], "esi_fetch_include mismatch: "..t["msg"] )
        end
        ngx.say("OK")
    }
}
location /f {
    content_by_lua_block {
        ngx.print("fragment", ngx.var.args or "")
    }
}
--- request
GET /t?test=foobar
--- no_error_log
[error]
--- response_body
OK

