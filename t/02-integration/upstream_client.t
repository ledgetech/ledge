use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_nginx_config => qq{
    lua_shared_dict test_upstream_dict 1m;
}, extra_lua_config => qq{
    function create_upstream_client(config)
        -- Defaults
        config = config or {}
        config["timeout"]      = config["timeout"] or 100
        config["read_timeout"] = config["read_timeout"] or 500
        config["host"]         = config["host"] or "$LedgeEnv::nginx_host"
        config["port"]         = config["port"] or $LedgeEnv::nginx_port

        return function(handler)
            local httpc = require("resty.http").new()
            httpc:set_timeout(config.timeout)

            local ok, err = httpc:connect(
                config.host,
                config.port
            )

            if not ok then
                ngx.log(ngx.ERR, "upstream client connection failed: ", err)
                return nil
            end

            httpc:set_timeout(config.read_timeout)

            handler.upstream_client = httpc
        end
    end

    require("ledge").bind("before_upstream_connect", function(handler)
        if ngx.req.get_uri_args()["skip_init"] then
            -- do nothing
        else
            -- create handler and pass through res
            create_upstream_client()(handler)
        end
    end)

    require("ledge").set_handler_defaults({
        upstream_host = "",
        upstream_port = 9999,
    })
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Sanity, response returned with upstream_client configured
--- http_config eval: $::HttpConfig
--- config
location /upstream_client_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /upstream_client {
    content_by_lua_block {
        ngx.say("OK")
    }
}
--- request
GET /upstream_client_prx
--- no_error_log
[error]
--- error_code: 200
--- response_body
OK

=== TEST 1b: Sanity, response returned with upstream_client configured at runtime
--- http_config eval: $::HttpConfig
--- config
location /upstream_client_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local h = require("ledge").create_handler()
        h:bind("before_upstream_connect", create_upstream_client() )
        h:run()
    }
}
location /upstream_client {
    content_by_lua_block {
        ngx.say("OK")
    }
}
--- request
GET /upstream_client_prx?skip_init=true
--- no_error_log
[error]
--- error_code: 200
--- response_body
OK

=== TEST 2: Short read timeout results in error 524.
--- http_config eval: $::HttpConfig
--- config
location /upstream_client_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /upstream_client {
    content_by_lua_block {
        ngx.sleep(1)
        ngx.say("OK")
    }
}
--- request
GET /upstream_client_prx
--- error_code: 524
--- response_body
--- error_log
timeout


=== TEST 3: No upstream results in a 503.
--- http_config eval: $::HttpConfig
--- config
location /upstream_client_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local h = require("ledge").create_handler()
        h:bind("before_upstream_connect", function(handler)
            handler.upstream_client = {}
        end)
        h:run()
    }
}
--- request
GET /upstream_client_prx
--- error_code: 503
--- response_body
--- error_log
upstream connection failed
