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


=== TEST 2: handle_range_request
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local range = require("ledge.range").new()
        local args = ngx.req.get_uri_args()

        -- Response stub
        local response = {
            status = tonumber(args.status),
            size = tonumber(args.size),
            header = {}
        }

        local range_applied = false
        response, range_applied = range:handle_range_request(response)

        local t = tonumber(ngx.req.get_uri_args().t)
        if t == 1 then
            assert(response and not range_applied,
                "response should not be nil but range was not applied")
        elseif t == 2 then
            assert(response and range_applied,
                "response should not be nil and range should be applied")

            assert(response.status == 206,
                "status should be 206")

            assert(response.header["Content-Range"] == "bytes 0-99/200",
                "content_range header should be set")
        elseif t == 3 then
            assert(response and range_applied,
                "response should not be nil and range should be applied")

            assert(response.status == 206,
                "status should be 206")

            assert(response.header["Content-Range"] == "bytes 0-70/200",
                "content_range header should be set to coalesced ranges")

        elseif t == 4 then
            assert(response and range_applied,
                "response should not be nil and range should be applied")

            assert(response.status == 206,
                "status should be 206")

            assert(response.header["Content-Range"] == "bytes 0-199/200",
                "Content-Range header should be expanded to size")

        elseif t == 5 then
            assert(response and range_applied,
                "response should not be nil and range should be applied")

            assert(response.status == 206,
                "status should be 206")

            local ct = response.header["Content-Type"]
            assert(string.find(ct, "multipart/byteranges;"),
                "Content-Type header should incude multipart/byteranges")

        elseif t == 6 then
            assert(response and not range_applied,
                "response should not be nil but range was not applied")

            assert(response.status == 416,
                "status should be 416 (Not Satisfiable)")

        elseif t == 7 then
            assert(response and not range_applied,
                "response should not be nil but range was not applied")

        end
    }
}
--- more_headers eval
[
    "",
    "Range: bytes=0-99",
    "Range: bytes=0-30,20-70",
    "Range: bytes=0-",
    "Range: bytes=0-10,20-30",
    "Range: bytes=40-20",
    "Range: bytes=0-10",
]
--- request eval
[
    "GET /t?t=1&size=100&status=200",
    "GET /t?t=2&size=200&status=200",
    "GET /t?t=3&size=200&status=200",
    "GET /t?t=4&size=200&status=200",
    "GET /t?t=5&size=200&status=200",
    "GET /t?t=6&size=200&status=200",
    "GET /t?t=7&size=200&status=404",
]
--- no_error_log
[error]


=== TEST 3: get_range_request_filter
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local range = require("ledge.range").new()
        local args = ngx.req.get_uri_args()

        -- Response stub
        local response = {
            status = 200,
            size = 10,
            header = {},
            body_reader = coroutine.wrap(function()
                coroutine.yield("01234")
                coroutine.yield("56789")
            end),
        }

        if args["type"] then
            response.header["Content-Type"] = args["type"]
        end

        local function read_body(response)
            local res = ""
            repeat
                local chunk, err = response.body_reader()
                if chunk then
                    res = res .. chunk
                end
            until not chunk
            return res
        end

        local range_applied = false
        response, range_applied = range:handle_range_request(response)
        if range_applied then
            response.body_reader = range:get_range_request_filter(
                response.body_reader
            )
        end
        local body = read_body(response)

        local t = tonumber(ngx.req.get_uri_args().t)
        if t == 1 then
            assert(body == "0123456789", "body should be un-filtered")

        elseif t == 2 then
            assert(body == "0123", "body should be 0123")

        elseif t == 3 then
            assert(body == "2345678", "body should be 2345678")

        elseif t == 4 then
            assert(body == "456789", "body should be 456789")

        elseif t == 5 then
            assert(body == "23456789", "body should be 23456789")

        elseif t == 6 then
            assert(response.status == 206, "status should be 206")

            local ct = response.header["Content-Type"]
            assert(string.find(ct, "multipart/byteranges;"),
                "Content-Type header should incude multipart/byteranges")

            assert(ngx.re.find(
                body,
                [[^(Content-Range: bytes 0-4\/10\n$)]],
                "m"
            ), "body should contain Content-Range bytes 0-4/10")

            assert(ngx.re.find(
                body,
                [[^Content-Range: bytes 6-9\/10\n$]],
                "m"
            ), "body should contain Content-Range bytes 6-9/10")

        elseif t == 7 then
            assert(body == "3456789", "ranges should be coalesced")

        elseif t == 8 then
            assert(body == "0123456789", "body should be unfiltered")
            assert(response.status == 206, response.status)
            assert(response.header["Content-Range"] == "bytes 0-9/10",
                "Content-Range header should be trimmed to size")

        end
    }
}
--- more_headers eval
[
    "Range: bytes=0-9",
    "Range: bytes=0-3",
    "Range: bytes=2-8",
    "Range: bytes=4-",
    "Range: bytes=-8",
    "Range: bytes=0-4,6-9",
    "Range: bytes=0-4,6-9",
    "Range: bytes=3-6,6-9",
    "Range: bytes=0-11",
]
--- request eval
[
    "GET /t?t=1",
    "GET /t?t=2",
    "GET /t?t=3",
    "GET /t?t=4",
    "GET /t?t=5",
    "GET /t?t=6",
    "GET /t?t=6&type=text/html",
    "GET /t?t=7",
    "GET /t?t=8",
]
--- no_error_log
[error]


=== TEST 4: parse_content_range
--- http_config eval: $::HttpConfig
--- config
location /t {
    content_by_lua_block {
        local parse_content_range = require("ledge.range").parse_content_range

        local from, to, size = parse_content_range("bytes 1-2/3")
        assert(from == 1 and to == 2 and size == 3)

        from, to, size = parse_content_range("byte 1-2/3")
        assert(not from and not to and not size)

        from, to, size = parse_content_range("bytes 123-1234/12345")
        assert(from == 123 and to == 1234 and size == 12345)
    }
}
--- request
GET /t
--- no_error_log
[error]
