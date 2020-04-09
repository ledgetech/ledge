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
    my ($extra_config) = @_ || "";

    return qq{
        lua_package_path "./lib/?.lua;;";
        resolver local=on;

        init_by_lua_block {
            if $LedgeEnv::test_coverage == 1 then
                require("luacov.runner").init()
            end

            local REDIS_URL = "redis://$LedgeEnv::redis_host:$LedgeEnv::redis_port/$LedgeEnv::redis_database"

            require("ledge").configure({
                redis_connector_params = { url = REDIS_URL },
                qless_db = $LedgeEnv::redis_qless_database,
            })

            require("ledge").set_handler_defaults({
                upstream_host = "$LedgeEnv::nginx_host",
                upstream_port = $LedgeEnv::nginx_port,
                storage_driver_config = {
                    redis_connector_params = { url = REDIS_URL },
                },
            })

            require("ledge.state_machine").set_debug(true)

            $extra_config;
        }
    }
}

our @EXPORT = qw( http_config );

1;
