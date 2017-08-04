use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
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

    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = $ENV{TEST_NGINX_PORT},
        storage_driver_config = {
            redis_connector_params = {
                db = $ENV{TEST_LEDGE_REDIS_DATABASE},
            },
        }
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
=== TEST 1: GET
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
        ngx.say(ngx.req.get_method())
    }
}
--- request
GET /req_method_1_prx
--- response_body
GET
--- no_error_log
[error]


=== TEST 2: HEAD gets GET request
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1
--- no_error_log
[error]


=== TEST 3: HEAD revalidate
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_1"
    }
}
--- more_headers
Cache-Control: max-age=0
--- request
HEAD /req_method_1_prx
--- response_headers
Etag: req_method_1
--- no_error_log
[error]


=== TEST 4: GET still has body
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_1
--- response_body
GET
--- no_error_log
[error]


=== TEST 5: POST does not get cached copy
--- http_config eval: $::HttpConfig
--- config
location /req_method_1_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /req_method_1 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Etag"] = "req_method_posted"
        ngx.say(ngx.req.get_method())
    }
}
--- request
POST /req_method_1_prx
--- response_headers
Etag: req_method_posted
--- response_body
POST
--- no_error_log
[error]


=== TEST 6: GET uses cached POST response.
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /req_method_1
--- response_headers
Etag: req_method_posted
--- response_body
POST
--- no_error_log
[error]


=== TEST 7: 501 on unrecognised method
--- http_config eval: $::HttpConfig
--- config
location /req_method_1 {
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
FOOBAR /req_method_1
--- error_code: 501
--- no_error_log
[error]
