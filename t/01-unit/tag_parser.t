use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_lua_config => qq{
    function print_next(tag, before, after)
        if not tag.closing then
            tag.closing = {}
        end
        ngx.say(tag.closing.from)
        ngx.say(tag.closing.to)
        ngx.say(tag.closing.tag)
        ngx.say(tag.whole)
        ngx.say(tag.contents)
        ngx.say(before)
        ngx.say(after)
    end
    function strip_whitespace(content)
        return ngx.re.gsub(content, [[\\s*\\n\\s*]], "")
    end
    function check_regex(regex, content, msg)
         local to, from = ngx.re.find(content, regex, "soj")
         assert(from ~= nil and to ~= nil, (msg or "regex should match"))
    end
});

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Load module
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local parser = tag_parser.new("Content")
        assert(parser, "tag_parser.new should return positively")

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

=== TEST 2: Find next tag
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local parser = tag_parser.new("content-before<foo>inside</foo>content-after")
        assert(parser, "tag_parser.new should return positively")

        local tag, before, after = parser:next("foo")
        assert(tag, "next should find a tag")
        print_next(tag, before, after)
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
26
31
</foo>
<foo>inside</foo>
inside
content-before
content-after

=== TEST 3: Default next tag finds esi
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local parser = tag_parser.new("content-before<esi:foo>inside</esi:foo>content-after<!--esi comment-->last")
        assert(parser, "tag_parser.new should return positively")

        local tag, before, after = parser:next()
        assert(tag, "next should find a tag")
        print_next(tag, before, after)

        ngx.say("##########")

        local tag, before, after = parser:next()
        assert(tag, "next should find a tag")
        print_next(tag, before, after)
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
30
39
</esi:foo>
<esi:foo>inside</esi:foo>
inside
content-before
content-after<!--esi comment-->last
##########
68
70
-->
<!--esi comment-->
comment
content-after
last

=== TEST 4: Find tag with attributes
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local parser = tag_parser.new("content-before<foo attr='value' attr2='value2'>inside</foo>content-after")
        assert(parser, "tag_parser.new should return positively")

        local tag, before, after = parser:next("foo")
        assert(tag, "next should find a tag")
        print_next(tag, before, after)
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
54
59
</foo>
<foo attr='value' attr2='value2'>inside</foo>
attr='value' attr2='value2'>inside
content-before
content-after

=== TEST 4: Find nested tags
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local content = strip_whitespace([[
content-before
<foo>
    inside-foo
    <bar>
        inside-bar
    </bar>
    after-bar
    <foo>
        inside-foo-2
    </foo>
</foo>
content-after
]])

        local parser = tag_parser.new(content)
        assert(parser, "tag_parser.new should return positively")

        local tag, before, after = parser:next("foo")
        assert(tag, "next should find a tag")
        print_next(tag, before, after)

        ngx.say("#######")

        local parser = tag_parser.new(content)
        assert(parser, "tag_parser.new should return positively")

        local tag, before, after = parser:next("bar")
        assert(tag, "next should find a tag")
        print_next(tag, before, after)
    }
}

--- request
GET /t
--- error_code: 200
--- no_error_log
[error]
--- response_body
83
88
</foo>
<foo>inside-foo<bar>inside-bar</bar>after-bar<foo>inside-foo-2</foo></foo>
inside-foo<bar>inside-bar</bar>after-bar<foo>inside-foo-2</foo>
content-before
content-after
#######
45
50
</bar>
<bar>inside-bar</bar>
inside-bar
content-before<foo>inside-foo
after-bar<foo>inside-foo-2</foo></foo>content-after

=== TEST 5: Pattern functions return valid regex
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local ok, err = ngx.re.find("", tag_parser.open_pattern("tag"))
        assert(err == nil, "open_pattern should return a valid regex")

        local ok, err = ngx.re.find("", tag_parser.close_pattern("tag"))
        assert(err == nil, "open_pattern should return a valid regex")

        local ok, err = ngx.re.find("", tag_parser.either_pattern("tag"))
        assert(err == nil, "open_pattern should return a valid regex")

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

=== TEST 5: open pattern matches
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local regex = tag_parser.open_pattern("tag")
        ngx.log(ngx.DEBUG, regex)

        local checks = {
            "start <tag> end", "simple tag",
            "start <tag></tag> end", "simple closed tag",
            "start <tag> asdfsd </tag> end", "simple closed tag with content",
            "start <tag > end", "simple tag whitespace",
            "start <tag/> end", "self-closing tag",
            "start <tag /> end", "self-closing tag whitespace",
            "start <tag end", "unclosed tag",
            "start <tag attr='value'> end", "simple tag with attribute",
            'start <tag attr="value"> end', "simple tag with attribute (single-quote)",
            'start <tag attr123="value123"> end', "simple tag with attribute (numeric)",
            'start <tag attr_123-foo="value 123-test_"> end', "simple tag with attribute (special chars)",
        }

        for i=1,#checks,2 do
            check_regex(regex, checks[i], "open_pattern should match "..checks[i+1])
        end

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

=== TEST 6: close pattern matches
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local regex = tag_parser.close_pattern("tag")
        ngx.log(ngx.DEBUG, regex)

        local checks = {
            "start </tag> end", "simple tag",
            "start <tag></tag> end", "simple closed tag",
            "start <tag> asdfsd </tag> end", "simple closed tag with content",
            "start </tag > end", "simple tag with whitespace",
        }

        for i=1,#checks,2 do
            check_regex(regex, checks[i], "close_pattern should match "..checks[i+1])
        end

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

=== TEST 7: either pattern matches
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local tag_parser = assert(require("ledge.esi.tag_parser"),
            "module should load without errors")

        local regex = tag_parser.either_pattern("tag")
        ngx.log(ngx.DEBUG, regex)

        local checks = {
            "start <tag> end", "simple tag",
            "start <tag></tag> end", "simple closed tag",
            "start <tag> asdfsd </tag> end", "simple closed tag with content",
            "start <tag > end", "simple tag whitespace",
            "start <tag/> end", "self-closing tag",
            "start <tag /> end", "self-closing tag whitespace",
            "start <tag end", "unclosed tag",
            "start <tag attr='value'> end", "simple tag with attribute",
            'start <tag attr="value"> end', "simple tag with attribute (single-quote)",
            'start <tag attr123="value123"> end', "simple tag with attribute (numeric)",
            'start <tag attr_123-foo="value 123-test_"> end', "simple tag with attribute (special chars)",

            "start </tag> end", "simple tag",
            "start <tag></tag> end", "simple closed tag",
            "start <tag> asdfsd </tag> end", "simple closed tag with content",
            "start </tag > end", "simple tag with whitespace",
        }

        for i=1,#checks,2 do
            check_regex(regex, checks[i], "either_pattern should match "..checks[i+1])
        end

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
