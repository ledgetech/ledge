use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 4;
log_level('debug');
my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} ||= 1;

our $HttpConfig = qq{
	lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict test 1m;
	init_by_lua "
        local test = ngx.shared.test
        
        test:set('collapsed_count',0)
        test:set('uncollapsed_count',0)

		ledge_mod = require 'ledge.ledge'

        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('origin_location','/__origin')

        function origin_response(counter)
            local ngx = ngx
            local test = ngx.shared.test
            local res,err = test:incr(counter,1)
            ngx.header['Cache-Control'] = 'max-age=3600'
            ngx.header['Last-Modified'] = ngx.http_time(ngx.time())
            ngx.header['Date'] = ngx.http_time(ngx.time())

            if res == 1 then
                ngx.say('PRIME:' .. res)
            elseif res == 2 then
                ngx.sleep(0.5)
                ngx.say('MASTER:' .. res)
            elseif res == 3 then
                ngx.sleep(1) 
                --[[ 
                    Sleep for longer than the master -
                    that way if we actually HIT this section
                    (collapse failed or nocollapse test), then we dont
                    receive a socket timeout (issue with ledge / echo
                    returning out-of-order responses?? who knows).
                ]]--
                ngx.say('CHILD:' .. res)
            else
                ngx.say('UNKNOWN:' .. res)
            end
        end
	";
};

run_tests();

__DATA__
=== TEST 1: Test collapsed forwarding
--- http_config eval: $::HttpConfig
--- config
    location /testcollapse {
        echo_location_async '/_ledge'; # Prime the cache
        echo_sleep 0.1;
        echo_location_async '/_ledge'; # Trigger collapsed master
        echo_sleep 0.05;
        echo_location_async '/_ledge'; # Trigger collapsed child
    }

    location /_ledge {
        rewrite ^/_ledge$ / break;
        content_by_lua '
            ledge:config_set("collapsed_forwarding",true)
            ledge:run()
        ';
    }

    location /__origin {
        rewrite ^/__origin(.*)$ $1 break;
        content_by_lua 'origin_response("collapsed_count")';
    }

--- more_headers
Cache-Control: no-cache
--- request
GET /testcollapse
--- timeout: 5
--- response_body
PRIME:1
MASTER:2
MASTER:2


=== TEST 2: Test no collapsed forwarding
--- http_config eval: $::HttpConfig
--- config

    location /testnocollapse {
        echo_location_async '/_ledge'; # Prime the cache
        echo_sleep 0.1;
        echo_location_async '/_ledge'; # Trigger collapsed master
        echo_sleep 0.05;
        echo_location_async '/_ledge'; # Trigger collapsed child
    }

    location /_ledge {
        rewrite ^/_ledge$ / break;
        content_by_lua '
            ledge:run()
        ';
    }

    location /__origin {
        rewrite ^/__origin(.*)$ $1 break;
        content_by_lua 'origin_response("uncollapsed_count")';
    }

--- more_headers
Cache-Control: no-cache
--- request
GET /testnocollapse
--- timeout: 5
--- response_body
PRIME:1
MASTER:2
CHILD:3

