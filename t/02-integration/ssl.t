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


	-- SSL helper function
	function do_ssl(ssl_opts, params)
		local ssl_opts = ssl_opts or {}

		if not ssl_opts.verify then
			ssl_opts.verify = false
		end

		if not ssl_opts.send_status_req then
			ssl_opts.send_status_req = false
		end

		local httpc_ssl = require("resty.http").new()
		local ok, err =
			httpc_ssl:connect("unix:$ENV{TEST_NGINX_HTML_DIR}/nginx-ssl.sock")

		if not ok then
			ngx.say("Unable to connect to sock, ", err)
			return ngx.exit(ngx.status)
		end

		session, err = httpc_ssl:ssl_handshake(
			nil,
			ssl_opts.sni_name,
            ssl_opts.verify,
            ssl_opts.send_status_req
        )

		if err then
			ngx.say("Unable to sslhandshake, ", err)
			return ngx.exit(ngx.status)
		end

		httpc_ssl:set_timeout(2000)

		if params then
			return httpc_ssl:request(params)
		else
			return httpc_ssl:proxy_request()
		end
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
[error]
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
[error]
--- response_body
OK https


=== TEST 4: Empty SSL name treated as nil
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /upstream_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            upstream_ssl_server_name = "",
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
[error]
--- response_body
OK https


=== TEST 9a: Prime another key
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /purge_ssl_entry {
    rewrite ^(.*)_entry$ $1_prx break;
    content_by_lua_block {
        local res, err = do_ssl(nil)
        ngx.print(res:read_body())
    }
}
location /purge_ssl_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_ssl {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9: ", ngx.req.get_headers()["Cookie"])
    }
}
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- more_headers
Cookie: primed
--- request
GET /purge_ssl_entry
--- no_error_log
[error]
--- response_body
TEST 9: primed


=== TEST 9b: Purge with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /purge_ssl_entry {
    rewrite ^(.*)_entry$ $1_prx break;
    content_by_lua_block {
        local res, err = do_ssl(nil)
        ngx.print(res:read_body())
    }
}
location /purge_ssl_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_ssl {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9 Revalidated: ", ngx.req.get_headers()["Cookie"])
    }
}
--- user_files eval
">>> rootca.pem
$::RootCACert
>>> example.com.key
$::ExampleKey
>>> example.com.crt
$::ExampleCert"
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_ssl_entry
--- wait: 2
--- no_error_log
[error]
--- response_body_like: "result":"purged"
--- error_code: 200


=== TEST 9c: Confirm cache was revalidated
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /purge_ssl_entry {
    rewrite ^(.*)_entry$ $1_prx break;
    content_by_lua_block {
        local res, err = do_ssl(nil)
        ngx.print(res:read_body())
    }
}
location /purge_ssl_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
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
GET /purge_ssl_entry
--- no_error_log
[error]
--- response_body
TEST 9 Revalidated: primed

=== TEST 10: ESI include fragment
--- log_level: debug
--- http_config eval: $::HttpConfig
--- config
listen unix:$TEST_NGINX_HTML_DIR/nginx-ssl.sock ssl;
location /esi_ssl_entry {
    rewrite ^(.*)_entry$ $1_prx break;
    content_by_lua_block {
        local res, err = do_ssl(nil)
        ngx.print(res:read_body())
    }
}
location /esi_ssl_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            esi_enabled = true,
        }):run()
    }
}
location /fragment_1 {
    content_by_lua_block {
        ngx.say("FRAGMENT: ", ngx.req.get_uri_args()["a"] or "", "|", ngx.var.scheme)
    }
}
location /esi_ssl {
    default_type text/html;
    content_by_lua_block {
        ngx.header["Surrogate-Control"] = [[content="ESI/1.0"]]
        ngx.say("1")
        ngx.print([[<esi:include src="/fragment_1" />]])
        ngx.say("2")
        ngx.print([[<esi:include src="/fragment_1?a=2" />]])
        ngx.print("3")
        ngx.print([[<esi:include src="http://127.0.0.1:1984/fragment_1?a=3" />]])
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
GET /esi_ssl_entry
--- raw_response_headers_unlike: Surrogate-Control: content="ESI/1.0\"\r\n
--- response_body
1
FRAGMENT: |https
2
FRAGMENT: 2|https
3FRAGMENT: 3|http
--- no_error_log
[error]
