use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 3) - 1; 

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
  lua_package_path "$pwd/../lua-resty-rack/lib/?.lua;$pwd/lib/?.lua;;";
  init_by_lua "
    ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
    ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
    ledge:config_set('redis_pass', $ENV{TEST_LEDGE_REDIS_DATABASE_PASSWORD})
  ";
};

run_tests();

__DATA__
=== TEST 1: Use authentication from configs.
--- http_config eval: $::HttpConfig
--- config
  location /auth_1 {
        echo "OK";
    }
--- request
GET /auth_1
--- no_error_log
[error]
