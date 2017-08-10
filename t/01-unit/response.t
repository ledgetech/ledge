use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-http/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    TEST_NGINX_PORT = $ENV{TEST_NGINX_PORT}
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
        local ok, err = require("ledge.response").new()
        assert(not ok, "new with empty args should return negatively")
        assert(string.find(err, "redis and key_chain args required"),
            "err should contain 'redis and key_chian args required'")


    }
}
--- request
GET /t
--- no_error_log
[error]

