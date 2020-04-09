package LedgeEnv;
use strict;
use warnings;
use Exporter;

our $nginx_host = $ENV{TEST_NGINX_HOST} || '127.0.0.1';
our $nginx_port = $ENV{TEST_NGINX_PORT} || 1984;
our $test_coverage = $ENV{TEST_COVERAGE} || 0;

our $redis_host = $ENV{TEST_LEDGE_REDIS_HOST} || '127.0.0.1';
our $redis_port = $ENV{TEST_LEDGE_REDIS_PORT} || 6379;
our $redis_database = $ENV{TEST_LEDGE_REDIS_DATABASE} || 2;
our $redis_qless_database = $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} || 3;

sub http_config {
    my $extra_nginx_config = "";
    my $extra_lua_config = "";
    my $worker_config = "";

    my (%args) = @_;

    if (defined $args{extra_nginx_config}) {
        $extra_nginx_config = $args{extra_nginx_config};
    }
    
    if (defined $args{extra_lua_config}) {
        $extra_lua_config = $args{extra_lua_config};
    }

    if ($args{run_worker}) {
        $worker_config = qq{
            init_worker_by_lua_block {
                require("ledge").create_worker():run()
            }
        };
    }

    return qq{
        $extra_nginx_config

        lua_package_path "./lib/?.lua;;";
        resolver local=on;

        init_by_lua_block {
            if $test_coverage == 1 then
                require("luacov.runner").init()
            end

            local REDIS_URL = "redis://$redis_host:$redis_port/$redis_database"

            require("ledge").configure({
                redis_connector_params = { url = REDIS_URL },
                qless_db = $redis_qless_database,
            })

            require("ledge").set_handler_defaults({
                upstream_host = "$nginx_host",
                upstream_port = $nginx_port,
                storage_driver_config = {
                    redis_connector_params = { url = REDIS_URL },
                },
            })

            $extra_lua_config;
        }

        $worker_config
    }
}

our @EXPORT = qw( http_config );

1;
