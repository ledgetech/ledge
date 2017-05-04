use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        jit.off()
        require("luacov.runner").init()
    end
}

}; # HttpConfig

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
        local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable

        -- Error if new field creation attempted
        local t = setmetatable({ a = 1, c = 3 }, fixed_field_metatable)
        local ok, err = pcall(
            function() t.b = 2 end,
            "attempt to create new field b"
        )
        assert(err == "attempt to create new field b")

        -- Error if non existent field dereferenced
        local t = setmetatable({ a = 1, c = 3 }, fixed_field_metatable)
        local ok, err = pcall(
            function() local a = t.b end,
            "attempt to create new field b"
        )
        assert(err == "field b does not exist")
    }
}
--- request
GET /t
--- no_error_log
[error]
