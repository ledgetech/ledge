use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Test hop-by-hop headers are not passed on.
--- http_config eval: $::HttpConfig
--- config
location /hop_by_hop_headers_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /hop_by_hop_headers {
    more_set_headers "Cache-Control public, max-age=600";
    more_set_headers "Proxy-Authenticate foo";
    more_set_headers "Upgrade foo";
    echo "OK";
}
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate:
Upgrade:
--- no_error_log
[error]


=== TEST 2: Test hop-by-hop headers were not cached.
--- http_config eval: $::HttpConfig
--- config
location /hop_by_hop_headers_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /hop_by_hop_headers_prx
--- response_headers
Proxy-Authenticate:
Upgrade:
--- no_error_log
[error]
