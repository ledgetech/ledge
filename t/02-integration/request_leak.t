use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;
$ENV{TEST_NGINX_PORT} |= 1984;

our $HttpConfig = qq{
resolver 8.8.8.8;
if_modified_since off;
lua_check_client_abort on;

lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

init_by_lua_block {
    if $ENV{TEST_COVERAGE} == 1 then
        require("luacov.runner").init()
    end

    require("ledge").configure({
        redis_connector_params = {
            db = $ENV{TEST_LEDGE_REDIS_DATABASE},
        },
        qless_db = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE},
    })

    TEST_LEDGE_REDIS_DATABASE = $ENV{TEST_LEDGE_REDIS_DATABASE}

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = TEST_LEDGE_REDIS_DATABASE,
            },
        },
        esi_enabled = false,
    })
}

init_worker_by_lua_block {
    require("ledge").create_worker():run()
}

};

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Aborted request does not leak body into subsequent request
--- http_config eval
"$::HttpConfig"

--- config
    location = /trigger {
        content_by_lua_block {

            -- Send broken request and close socket
            local broken_sock = ngx.socket.tcp()
            broken_sock:settimeout(5000)
            local ok, err = broken_sock:connect("127.0.0.1", ngx.var.server_port)
            broken_sock:send("POST /target?id=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 16\r\n\r\n123\r\n")
            broken_sock:close()

            -- Send valid request and leave socket open
            local valid_sock = ngx.socket.tcp()
            valid_sock:settimeout(1000)
            local ok, err = valid_sock:connect("127.0.0.1", ngx.var.server_port)
            valid_sock:send("GET /target?id=2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

            -- Wait and read until end of headers
            local header_reader = valid_sock:receiveuntil("\r\n\r\n")
            local headers
            repeat
                headers = header_reader()
            until headers

            ngx.log(ngx.INFO, "HEADERS: ", headers)

            -- We're expecting chunked encoding
            if not headers:find("chunked") then
                ngx.log(ngx.ERR, "Expected chunked response but no header indicating such, failed!")
                ngx.exit(400)
            end

            -- Read chunk length as base16
            local chunk_len = tonumber(valid_sock:receive('*l'), 16)

            -- Read full chunk off wire
            local body, err, partial
            repeat
                body, err, partial = valid_sock:receive(chunk_len)
            until body or err

            valid_sock:close()
        
            if err then
                ngx.exit(400)
            end

            ngx.print(body)
        }
    }

    location /target {
        rewrite /target$ /origin break;
        content_by_lua_block {
             ngx.req.set_header("Host", "127.0.0.2")

            require("ledge").create_handler():run()
        }
    }

    location = /origin {
        content_by_lua_block {
            ngx.req.read_body()
            local args, err = ngx.req.get_uri_args()
            local data = ngx.req.get_body_data() or ''
            local method = ngx.req.get_method() or ''
            ngx.print("ORIGIN-", args['id'], "-", method, ":", data)
            ngx.exit(200)
        }
    }

--- request
GET /trigger
--- response_body
ORIGIN-2-GET: