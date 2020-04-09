use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: No calculated Age header on cache MISS.
--- http_config eval: $::HttpConfig
--- config
location /age_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
    }
}
location /age {
    more_set_headers "Cache-Control public, max-age=600";
    echo "OK";
}
--- request
GET /age_prx
--- response_headers
Age:
--- no_error_log
[error]


=== TEST 2: Age header on cache HIT
--- http_config eval: $::HttpConfig
--- config
location /age_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            origin_mode = require("ledge").ORIGIN_MODE_AVOID
        }):run()
    }
}
location /age {
    more_set_headers "Cache-Control public, max-age=600";
    echo "OK";
}
--- request
GET /age_prx
--- response_headers_like
Age: \d+
--- no_error_log
[error]
