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
=== TEST 1: req_byte_ranges
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local req_byte_ranges = assert(require("ledge.range").req_byte_ranges,
            "range module should load without errors")

        local ranges = req_byte_ranges()

        local t = tonumber(ngx.req.get_uri_args().t)
        if t == 1 then
            assert(not ranges,
                "req_byte_ranges with no range header should return nil")

        elseif t == 2 then
            assert(ranges[1], "range should exist")
            assert(ranges[1].from == 0 and ranges[1].to == 99,
                "req_byte_ranges should be from 0 to 99")

        elseif t == 3 then
            assert(not ranges,
                "req_byte_ranges with malformed range header should return nil")

        elseif t == 4 then
            assert(ranges[1], "range should exist")
            assert(ranges[1].from == 0 and not ranges[1].to,
                "req_byte_ranges should be from 0 to nil")

        elseif t == 5 then
            assert(ranges[1], "range should exist")
            assert(not ranges[1].from and ranges[1].to == 99,
                "req_byte_ranges should be from 0 to 99")

        elseif t == 6 then
            assert(ranges[1], "range should exist")
            assert(not ranges[1].from and not ranges[1].to,
                "req_byte_ranges should be from 0 to 99")

        elseif t == 7 then
            assert(ranges[1] and ranges[2] and not ranges[3],
                "two ranges should exist")

            assert(ranges[1].from == 0 and ranges[1].to == 10,
                "ranges[1] should be from 0 to 10")

            assert(ranges[2].from == 20 and ranges[2].to == 30,
                "ranges[2] should be 20 to 30")

        elseif t == 8 then
            assert(ranges[1] and ranges[2] and not ranges[3],
                "two ranges should exist")

            assert(ranges[1].from == 0 and not ranges[1].to,
                "ranges[1] should be from 0 to nil")

            assert(not ranges[2].from and ranges[2].to == 30,
                "ranges[2] should be nil to 30")

        end
    }
}
--- more_headers eval
[
    "",
    "Range: bytes=0-99",
    "Range: 0-99",
    "Range: bytes=0-",
    "Range: bytes=-99",
    "Range: bytes=-",
    "Range: bytes=0-10,20-30",
    "Range: bytes=0-,-30",
]
--- request eval
[
    "GET /t?t=1",
    "GET /t?t=2",
    "GET /t?t=3",
    "GET /t?t=4",
    "GET /t?t=5",
    "GET /t?t=6",
    "GET /t?t=7",
    "GET /t?t=8",
]
--- no_error_log
[error]
