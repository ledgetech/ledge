use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 5; 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    
    init_by_lua "
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ";
};

run_tests();

__DATA__
=== TEST 1: Warning when unable to set client abort handler
--- http_config eval: $::HttpConfig
--- config
    location /abort {
        lua_check_client_abort off;
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        echo 'foo';
    }
--- request
GET /abort

--- error_log
on_abort handler not set

=== TEST 2: Client abort should abort sub-request
--- http_config eval: $::HttpConfig
--- config
    location /abort {
        lua_check_client_abort on;
        content_by_lua '
            ledge:run()
        ';
    }
    location /__ledge_origin {
        content_by_lua '
        ngx.log(ngx.WARN, "Origin Start")
        ngx.sleep(1)
        ngx.log(ngx.ERR, "Origin Finish")
       ';
    }
--- request
GET /abort

--- timeout: 0.5
--- wait: 1
--- abort
--- ignore_response
--- no_error_log
[error]

=== TEST 3a: Client abort should remove collapse key - prime
--- http_config eval: $::HttpConfig
--- config
    location /abort {
        lua_check_client_abort on;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:bind("before_save", function(res)
                -- immediately expire cache entries
                res.header["Cache-Control"] = "max-age=0"
            end)            
            ledge:run()
        ';
    }
    location /__ledge_origin {
            content_by_lua '
               ngx.header["Cache-Control"] = "max-age=3600"
               ngx.say("OK")
           ';
    }
--- request
GET /abort

=== TEST 3b: Client abort should remove collapse key - abort
--- http_config eval: $::HttpConfig
--- config
    location /abort {
        lua_check_client_abort on;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /__ledge_origin {
            content_by_lua '
            ngx.sleep(1)
           ';
    }
--- request
GET /abort

--- timeout: 0.5
--- wait: 1
--- abort
--- ignore_response

=== TEST 3c: Client abort should remove collapse key - should not collapse
--- http_config eval: $::HttpConfig
--- config
    location /abort {
        lua_check_client_abort on;
        content_by_lua '
            ledge:config_set("enable_collapsed_forwarding", true)
            ledge:run()
        ';
    }
    location /__ledge_origin {
            content_by_lua '
            ngx.exit(200)
           ';
    }
--- request
GET /abort

--- timeout: 0.5
--- abort
