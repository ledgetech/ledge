use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Should pass through request body
--- http_config eval: $::HttpConfig
--- config
location /cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /cached {
    content_by_lua_block {
        ngx.req.read_body()
        ngx.say({ngx.req.get_body_data()})
    }
}
--- request
POST /cached_prx
requestbody
--- response_body
requestbody
