use Test::Nginx::Socket 'no_plan';
use Cwd qw(cwd);

my $pwd = cwd();

$ENV{TEST_NGINX_PORT} |= 1984;
$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_COVERAGE} ||= 0;
$ENV{TEST_NGINX_HTML_DIR} ||= html_dir();

sub read_file {
    my $infile = shift;
    open my $in, $infile
        or die "cannot open $infile for reading: $!";
    my $cert = do { local $/; <$in> };
    close $in;
    $cert;
}

our $RootCACert = read_file("t/cert/rootCA.pem");
our $ExampleCert = read_file("t/cert/example.com.crt");
our $ExampleKey = read_file("t/cert/example.com.key");

our $HttpConfig = qq{
lua_package_path "./lib/?.lua;../lua-resty-redis-connector/lib/?.lua;../lua-resty-qless/lib/?.lua;../lua-resty-http/lib/?.lua;../lua-ffi-zlib/lib/?.lua;;";

lua_ssl_trusted_certificate "../html/rootca.pem";
ssl_certificate "../html/example.com.crt";
ssl_certificate_key "../html/example.com.key";

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
        upstream_host = "unix:$ENV{TEST_NGINX_HTML_DIR}/nginx-ssl.sock",
        upstream_use_ssl = true,
        upstream_ssl_server_name = "example.com",
        upstream_ssl_verify = true,
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
=== TEST 1: SSL works
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /upstream {
    content_by_lua_block {
        ngx.say("OK ", ngx.var.scheme)
    }
}
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- request
GET /upstream_prx
--- error_code: 200
--- no_error_log
[errror]
--- response_body
OK https


=== TEST 2: Bad SSL name errors
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_ssl_server_name = "foobar",
        }):run()
    }
}
location /upstream {
    content_by_lua_block {
        ngx.say("OK ", ngx.var.scheme)
    }
}
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- request
GET /upstream_prx
--- error_code: 525
--- error_log
ssl handshake failed
--- response_body:


=== TEST 3: SSL verification can be disabled
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_ssl_server_name = "foobar",
            upstream_ssl_verify = false
        }):run()
    }
}
location /upstream {
    content_by_lua_block {
        ngx.say("OK ", ngx.var.scheme)
    }
}
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- request
GET /upstream_prx
--- error_code: 200
--- no_error_log
[errror]
--- response_body
OK https
