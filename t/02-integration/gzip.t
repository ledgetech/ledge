use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config();

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime gzipped response
--- http_config eval: $::HttpConfig
--- config
location /gzip_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /gzip {
    gzip on;
    gzip_proxied any;
    gzip_min_length 1;
    gzip_http_version 1.0;
    default_type text/html;
    more_set_headers  "Cache-Control: public, max-age=600";
    more_set_headers  "Content-Type: text/html";
    echo "OK";
}
--- request
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 2: Client doesnt support gzip, gets plain response
--- http_config eval: $::HttpConfig
--- config
location /gzip_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /gzip_prx
--- response_body
OK
--- no_error_log
[error]


=== TEST 2b: Client doesnt support gzip, gunzip is disabled, gets zipped response
--- http_config eval: $::HttpConfig
--- config
location /gzip_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            gunzip_enabled = false,
        }):run()
    }
}
--- request
GET /gzip_prx
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 3: Client does support gzip, gets zipped response
--- http_config eval: $::HttpConfig
--- config
location /gzip_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- response_body_unlike: OK
--- no_error_log
[error]


=== TEST 4: Client does support gzip, but sends a range, gets plain full response
--- http_config eval: $::HttpConfig
--- config
location /gzip_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /gzip_prx
--- more_headers
Accept-Encoding: gzip
--- more_headers
Range: bytes=0-0
--- error_code: 200
--- response_body
OK
--- no_error_log
[error]


=== TEST 5: Prime gzipped response with ESI, auto unzips.
--- http_config eval: $::HttpConfig
--- config
location /gzip_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            esi_enabled = true,
        }):run()
    }
}
location /gzip_5 {
    gzip on;
    gzip_proxied any;
    gzip_min_length 1;
    gzip_http_version 1.0;
    default_type text/html;
    more_set_headers "Cache-Control: public, max-age=600";
    more_set_headers "Content-Type: text/html";
    more_set_headers 'Surrogate-Control: content="ESI/1.0"';
    echo "OK<esi:vars></esi:vars>";
}
--- request
GET /gzip_5_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
OK
--- no_error_log
[error]


=== TEST 6: Client does support gzip, but content had to be unzipped on save
--- http_config eval: $::HttpConfig
--- config
location /gzip_5_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /gzip_5_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
OK
--- no_error_log
[error]


=== TEST 7: HEAD request for gzipped response with ESI, auto unzips.
--- http_config eval: $::HttpConfig
--- config
location /gzip_7_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            esi_enabled = true,
        }):run()
    }
}
location /gzip_7 {
    gzip on;
    gzip_proxied any;
    gzip_min_length 1;
    gzip_http_version 1.0;
    default_type text/html;
    more_set_headers "Cache-Control: public, max-age=600";
    more_set_headers "Content-Type: text/html";
    more_set_headers 'Surrogate-Control: content="ESI/1.0"';
    echo "OK";
}
--- request
HEAD /gzip_7_prx
--- more_headers
Accept-Encoding: gzip
--- response_body
--- no_error_log
[error]
