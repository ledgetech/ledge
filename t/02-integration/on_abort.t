use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

lua_check_client_abort on;

upstream test-upstream {
    server 127.0.0.1:1984;
    keepalive 16;
}

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
run_tests();


__DATA__
=== TEST 1: Warning when unable to set client abort handler
--- http_config eval: $::HttpConfig
--- config
location /abort_prx {
    rewrite ^(.*)_prx$ $1 break;
    lua_check_client_abort off;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /abort {
    echo "foo";
}
--- request
GET /abort_prx
--- error_log
on_abort handler could not be set: lua_check_client_abort is off


=== TEST 2a: Client abort mid save should still save to cache (run and abort)
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
    location /abort {
        content_by_lua_block {
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.flush(true)
            ngx.sleep(2)
            ngx.say("FINISH")
       }
    }
--- request
GET /abort_prx
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 2b: Prove we have a complete cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]


=== TEST 3a: Client abort before save aborts fetching
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
    location /abort {
        content_by_lua_block {
            ngx.sleep(2)
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START 2")
            ngx.say("FINISH 2")
       }
    }
--- request
GET /abort_prx
--- more_headers
Cache-Control: max-age=0
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 3b: Prove we still have the previous cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]


=== TEST 4a: Prime immediately expiring cache item
--- http_config eval: $::HttpConfig
--- config
location /abort_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_save", function(res)
            -- immediately expire cache entries
            res.header["Cache-Control"] = "max-age=0"
        end)
        handler:run()
    }
}
location /abort {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("OK")
    }
}
--- more_headers
Cache-Control: no-cache
--- request
GET /abort_prx
--- response_body
OK
--- error_code: 200
--- no_error_log
[error]


=== TEST 4b: Client abort before fetch with collapsed forwarding on cancels abort
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            local handler = require("ledge").create_handler({
                enable_collapsed_forwarding = true,
            })
            handler:bind("before_upstream_request", function(res)
                ngx.sleep(2)
            end)
            handler:run()
        }
    }
    location /abort {
        content_by_lua_block {
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.say("FINISH")
       }
    }
--- request
GET /abort_prx
--- timeout: 1
--- wait: 1.5
--- abort
--- ignore_response
--- no_error_log
[error]


=== TEST 4c: Prove we have the previous cache entry
--- http_config eval: $::HttpConfig
--- config
    location /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
--- request
GET /abort_prx
--- response_body
START
FINISH
--- error_code: 200
--- no_error_log
[error]


=== TEST 5: No error when keepalive_requests exceeded
--- http_config eval: $::HttpConfig
--- config
    location = /abort_top {
        content_by_lua_block {
            local http = require "resty.http"
            local httpc = http.new()
            local res, err = httpc:request_uri(
                "http://" ..
                ngx.var.server_addr .. ":" .. ngx.var.server_port ..
                "/abort_ngx"
            )
            if not res then
                ngx.log(ngx.ERR, err)
            end

            local res, err = httpc:request_uri(
                "http://" ..
                ngx.var.server_addr .. ":" .. ngx.var.server_port ..
                "/abort_ngx"
            )
            if not res then
                ngx.log(ngx.ERR, err)
            end

            ngx.say("OK")
        }
    }
    location = /abort_ngx {
        rewrite ^ /abort_prx break;
        proxy_pass http://test-upstream;
    }
    location = /abort_prx {
        rewrite ^(.*)_prx$ $1 break;
        keepalive_requests 1;
        content_by_lua_block {
            require("ledge").create_handler():run()
        }
    }
    location = /abort {
        content_by_lua_block {
            ngx.status = 200
            ngx.header["Cache-Control"] = "public, max-age=3600"
            ngx.say("START")
            ngx.say("FINISH")
       }
    }
--- request
GET /abort_top
--- response_body
OK
--- error_code: 200
--- no_error_log
[error]
