use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (blocks() * 4) - 9;

my $pwd = cwd();

$ENV{TEST_LEDGE_REDIS_DATABASE} |= 2;
$ENV{TEST_LEDGE_REDIS_QLESS_DATABASE} |= 3;
$ENV{TEST_USE_RESTY_CORE} ||= 'nil';

our $HttpConfig = qq{
lua_package_path "$pwd/../lua-ffi-zlib/lib/?.lua;$pwd/../lua-resty-redis-connector/lib/?.lua;$pwd/../lua-resty-qless/lib/?.lua;$pwd/../lua-resty-http/lib/?.lua;$pwd/../lua-resty-cookie/lib/?.lua;$pwd/lib/?.lua;;";
    init_by_lua "
        local use_resty_core = $ENV{TEST_USE_RESTY_CORE}
        if use_resty_core then
            require 'resty.core'
        end
        ledge_mod = require 'ledge.ledge'
        ledge = ledge_mod:new()
        ledge:config_set('redis_database', $ENV{TEST_LEDGE_REDIS_DATABASE})
        ledge:config_set('redis_qless_database', $ENV{TEST_LEDGE_REDIS_QLESS_DATABASE})
        ledge:config_set('upstream_host', '127.0.0.1')
        ledge:config_set('upstream_port', 1984)
    ";
    init_worker_by_lua "
        ledge:run_workers()
    ";
};

no_long_string();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    ';
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 1


=== TEST 2: Purge cache
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        ledge:run()
    ';
}

--- request eval
["PURGE /purge_cached", "PURGE /purge_cached"]
--- no_error_log
[error]
--- response_body eval
['{"result":"purged","purge_mode":"invalidate"}',
'{"result":"already expired","purge_mode":"invalidate"}']
--- error_code eval
[200, 404]


=== TEST 3: Cache has been purged
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    ';
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 3


=== TEST 4: Purge on unknown key returns 404
--- http_config eval: $::HttpConfig
--- config
location /foobar {
    content_by_lua '
        ledge:run()
    ';
}

--- request
PURGE /foobar
--- no_error_log
--- response_body: {"result":"nothing to purge","purge_mode":"invalidate"}
--- error_code: 404


=== TEST 5a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 0)
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 5b: Wildcard Purge
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_cached*
--- wait: 1
--- no_error_log
[error]
--- response_body_like: {"result":"scheduled","qless_job":{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 5c: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 0)
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5c")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5c


=== TEST 5d: Cache has been purged without args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 0)
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5d")
    ';
}
--- request
GET /purge_cached_prx
--- no_error_log
[error]
--- response_body
TEST 5d


=== TEST 6a: Purge everything
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_c*
--- wait: 3
--- error_code: 200
--- response_body_like: {"result":"scheduled","qless_job":{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- no_error_log
[error]


=== TEST 6: Cache keys have been collected by Redis
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua '
        local redis_mod = require "resty.redis"
        local redis = redis_mod.new()
        redis:connect("127.0.0.1", 6379)
        redis:select(ledge:config_get("redis_database"))
        local key_chain = ledge:cache_key_chain()

        local res, err = redis:keys(key_chain.root .. "*")

        ngx.say("keys: ", table.getn(res))
    ';
}
--- request
GET /purge_cached
--- no_error_log
[error]
--- response_body
keys: 0


=== TEST 7a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 7b: Wildcard Purge, mid path (no match due to args)
--- http_config eval: $::HttpConfig
--- config
location /purge_c {
    content_by_lua '
        ledge:run()
    ';
}
--- request
PURGE /purge_ca*ed
--- wait: 1
--- no_error_log
[error]
--- response_body_like: {"result":"scheduled","qless_job":{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 7c: Confirm purge did nothing
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ngx.sleep(1) -- Wait for qless work
        ledge:run()
    ';
}
--- request
GET /purge_cached_prx?t=1
--- no_error_log
[error]
--- response_body
TEST 5


=== TEST 8a: Prime another key - with keep_cache_for set
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_8 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8")
    ';
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8


=== TEST 8b: Wildcard Purge (200)
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8 {
    content_by_lua '
        ledge:config_set("keyspace_scan_count", 1)
        ledge:run()
    ';
}
--- request
PURGE /purge_cached_8*
--- wait: 1
--- no_error_log
[error]
--- response_body_like: {"result":"scheduled","qless_job":{"klass":"ledge\.jobs\.purge","jid":"[a-f0-9]{32}","options":{"tags":\["purge"\],"jid":"[a-f0-9]{32}","priority":5}},"purge_mode":"invalidate"}
--- error_code: 200


=== TEST 8d: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached_8 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8c")
    ';
}
--- request
GET /purge_cached_8_prx
--- no_error_log
[error]
--- response_body
TEST 8c
--- error_code: 200


=== TEST 9a: Prime another key
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_9 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9: ", ngx.req.get_headers()["Cookie"])
    ';
}
--- more_headers
Cookie: primed
--- request
GET /purge_cached_9_prx
--- no_error_log
[error]
--- response_body
TEST 9: primed


=== TEST 9b: Purge with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_9 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9 Revalidated: ", ngx.req.get_headers()["Cookie"])
    ';
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_9_prx
--- wait: 2
--- no_error_log
[error]
--- response_body_like: {"result":"purged","qless_job":{"klass":"ledge\.jobs\.revalidate","jid":"[a-f0-9]{32}","options":{"tags":\["revalidate"\],"jid":"[a-z0-f]{32}","priority":4}},"purge_mode":"revalidate"}
--- error_code: 200


=== TEST 9c: Confirm cache was revalidated
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
--- request
GET /purge_cached_9_prx
--- no_error_log
[error]
--- response_body
TEST 9 Revalidated: primed


=== TEST 10a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached_10 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 10: ", ngx.req.get_uri_args()["a"], " ", ngx.req.get_headers()["Cookie"])
    ';
}
--- more_headers
Cookie: primed
--- request eval
[ "GET /purge_cached_10_prx?a=1", "GET /purge_cached_10_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "TEST 10: 1 primed", "TEST 10: 2 primed" ]


=== TEST 10b: Wildcard purge with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:run()
    ';
}
location /purge_cached_10 {
    rewrite ^(.*)$ $1_origin break;
    content_by_lua '
        local a = ngx.req.get_uri_args()["a"]
        ngx.log(ngx.DEBUG, "TEST 10 Revalidated: ", a, " ", ngx.req.get_headers()["Cookie"])
    ';
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_10_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body: {"result":"scheduled","qless_job":{"klass":"ledge.jobs.purge","jid":"552add99bcfe22e69fa03446b664e0a4","options":{"tags":["purge"],"jid":"552add99bcfe22e69fa03446b664e0a4","priority":5}},"purge_mode":"revalidate"}
--- error_log eval
["TEST 10 Revalidated: 1 primed", "TEST 10 Revalidated: 2 primed"]
--- error_code: 200


=== TEST 11a: Prime a key
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_11 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 11")
    ';
}
--- request
GET /purge_cached_11_prx
--- no_error_log
[error]
--- response_body: TEST 11


=== TEST 11b: Purge with X-Purge: delete
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_11_prx
--- no_error_log
[error]
--- response_body: {"result":"deleted","purge_mode":"delete"}
--- error_code: 200


=== TEST 11c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_11 {
    content_by_lua '
        ngx.print("ORIGIN")
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request
GET /purge_cached_11_prx
--- response_body: ORIGIN
--- no_error_log
[error]
--- error_code: 200


=== TEST 12a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_12 {
    content_by_lua '
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 12: ", ngx.req.get_uri_args()["a"])
    ';
}
--- request eval
[ "GET /purge_cached_12_prx?a=1", "GET /purge_cached_12_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "TEST 12: 1", "TEST 12: 2" ]


=== TEST 12b: Wildcard purge with X-Purge: delete
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_12_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body: {"result":"scheduled","qless_job":{"klass":"ledge.jobs.purge","jid":"bc2dbf12d53b08f676f09be39b4ad121","options":{"tags":["purge"],"jid":"bc2dbf12d53b08f676f09be39b4ad121","priority":5}},"purge_mode":"delete"}
--- error_code: 200


=== TEST 12c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua '
        ledge:config_set("keep_cache_for", 3600)
        ledge:run()
    ';
}
location /purge_cached_12 {
    content_by_lua '
        ngx.print("ORIGIN: ", ngx.req.get_uri_args()["a"])
    ';
}
--- more_headers
Cache-Control: max-stale=1000
--- request eval
[ "GET /purge_cached_12_prx?a=1", "GET /purge_cached_12_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "ORIGIN: 1", "ORIGIN: 2" ]


=== TEST 13a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        if ngx.req.get_uri_args()["sabotage"] then
            -- Set query string to match original request
            ngx.req.set_uri_args({a=1})

            -- Connect to redis
            local redis = require("resty.redis"):new()
            redis:connect("127.0.0.1", 6379)
            redis:select(ledge:config_get('redis_database'))

            -- Get the subkeys
            local key = ledge.cache_key(ledge)
            local entity = redis:get(key.."::key")
            local cache_keys = ledge.entity_keys( key .. "::" .. entity)

            -- Bust the entity
            redis:del(cache_keys.main)
            ngx.print("Sabotaged: ", key)
        else
            ledge:run()
        end
    }
}
location /purge_cached_13 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 13: ", ngx.req.get_uri_args()["a"], " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
Cookie: primed
--- request eval
[ "GET /purge_cached_13_prx?a=1", "GET /purge_cached_13_prx?a=2", "GET /purge_cached_13_prx?a=1&sabotage=true" ]
--- no_error_log
[error]
--- response_body eval
[ "TEST 13: 1 primed", "TEST 13: 2 primed", "Sabotaged: ledge:cache:http:localhost:/purge_cached_13:a=1" ]


=== TEST 13b: Wildcard purge broken entry with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        ledge:run()
    }
}
location /purge_cached_13 {
    rewrite ^(.*)$ $1_origin break;
    content_by_lua_block {
        local a = ngx.req.get_uri_args()["a"]
        ngx.log(ngx.DEBUG, "TEST 13 Revalidated: ", a, " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_13_prx?*
--- wait: 2
--- error_log eval
["Entity broken: ledge:cache:http:localhost:/purge_cached_13:a=1", "TEST 13 Revalidated: 2 primed"]
--- response_body: {"result":"scheduled","qless_job":{"klass":"ledge.jobs.purge","jid":"98fcbee1f37f4dba0b48b0bc49cd162e","options":{"tags":["purge"],"jid":"98fcbee1f37f4dba0b48b0bc49cd162e","priority":5}},"purge_mode":"revalidate"}
--- error_code: 200
