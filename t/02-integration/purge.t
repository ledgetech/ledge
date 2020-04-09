use Test::Nginx::Socket 'no_plan';
use FindBin;
use lib "$FindBin::Bin/..";
use LedgeEnv;

our $HttpConfig = LedgeEnv::http_config(extra_nginx_config => qq{
    lua_shared_dict ledge_test 1m;
}, extra_lua_config => qq{
    function format_json(json, prefix)
        local decode = require("cjson").decode
        if type(json) == "string" then
            local ok
            ok, json = pcall(decode, json)
            if not ok then return "" end
        end
        local keys = {}
        for k, v in pairs(json) do
            table.insert(keys, k)
        end
        table.sort(keys)

        local fmt = "%s: %s\\n"
        local out = ""
        for i, k in ipairs(keys) do
            local key = k
            if prefix then
                key = prefix.."."..k
            end
            if type(json[k]) == "table" then
                out = out .. format_json(json[k], key)
            else
                out = out .. fmt:format(key, json[k])
            end
        end
        return out
    end
}, run_worker => 1);

no_long_string();
no_diff();
run_tests();

__DATA__
=== TEST 1: Prime cache for subsequent tests
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 1")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}

--- request eval
["PURGE /purge_cached", "PURGE /purge_cached"]
--- no_error_log
[error]
--- response_body eval
[
'purge_mode: invalidate
result: purged
',
'purge_mode: invalidate
result: already expired
']
--- error_code eval
[200, 404]


=== TEST 3: Cache has been purged
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 3")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}

--- request
PURGE /foobar
--- no_error_log
[error]
--- response_body
purge_mode: invalidate
result: nothing to purge

--- error_code: 404


=== TEST 5a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local handler = require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- request
PURGE /purge_cached*
--- wait: 1
--- no_error_log
[error]
--- response_body_like
purge_mode: invalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_code: 200


=== TEST 5c: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5c")
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 0,
        }):run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5d")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- request
PURGE /purge_c*
--- wait: 3
--- error_code: 200
--- response_body_like
purge_mode: invalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
--- no_error_log
[error]


=== TEST 6: Cache keys have been collected by Redis
--- http_config eval: $::HttpConfig
--- config
location /purge_cached {
    content_by_lua_block {
        local redis = require("ledge").create_redis_connection()
        local handler = require("ledge").create_handler()
        handler.redis = redis
        local key_chain = handler:cache_key_chain()

        local num_entities, err = redis:scard(key_chain.entities)
        ngx.say("entities: ", num_entities)
    }
}
--- request
GET /purge_cached
--- no_error_log
[error]
--- response_body
entities: 0


=== TEST 7a: Prime another key with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 5")
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- request
PURGE /purge_ca*ed
--- wait: 1
--- no_error_log
[error]
--- response_body_like
purge_mode: invalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_code: 200


=== TEST 7c: Confirm purge did nothing
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_8 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8")
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keyspace_scan_count = 1,
        }):run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- request
PURGE /purge_cached_8*
--- wait: 1
--- no_error_log
[error]
--- response_body_like
purge_mode: invalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_code: 200


=== TEST 8d: Cache has been purged with args
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_8_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_8 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 8c")
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_9 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9: ", ngx.req.get_headers()["Cookie"])
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_9 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9 Revalidated: ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_9_prx
--- no_error_log
[error]
--- response_body_like
purge_mode: revalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.revalidate
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 4
qless_jobs.1.options.tags.1: revalidate
result: purged
--- error_code: 200


=== TEST 9c: Wait for revalidation to complete
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_9 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.say("TEST 9 Revalidated: ", ngx.req.get_headers()["Cookie"])
    }
}
location /waiting {
  echo "OK";
}
--- request
GET /waiting
--- response_body
OK
--- no_error_log
[error]
--- wait: 5


=== TEST 9d: Confirm cache was revalidated
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_9_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
--- request
GET /purge_cached_9_prx
--- wait: 3
--- no_error_log
[error]
--- response_body
TEST 9 Revalidated: primed


=== TEST 10a: Prime two keys
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_10_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
}
location /purge_cached_10 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 10: ", ngx.req.get_uri_args()["a"], " ", ngx.req.get_headers()["Cookie"])
    }
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
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_10 {
    rewrite ^(.*)$ $1_origin break;
    content_by_lua_block {
        local a = ngx.req.get_uri_args()["a"]
        ngx.log(ngx.DEBUG, "TEST 10 Revalidated: ", a, " ", ngx.req.get_headers()["Cookie"])
    }
}
--- more_headers
X-Purge: revalidate
--- request
PURGE /purge_cached_10_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body_like
purge_mode: revalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_log
TEST 10 Revalidated: 1 primed
TEST 10 Revalidated: 2 primed
--- error_code: 200


=== TEST 11a: Prime a key
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_11 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 11")
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_11_prx
--- no_error_log
[error]
--- response_body
purge_mode: delete
result: deleted
--- error_code: 200


=== TEST 11c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_11_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_11 {
    content_by_lua_block {
        ngx.print("ORIGIN")
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_12 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 12: ", ngx.req.get_uri_args()["a"])
    }
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
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
--- more_headers
X-Purge: delete
--- request
PURGE /purge_cached_12_prx?*
--- wait: 2
--- no_error_log
[error]
--- response_body_like
purge_mode: delete
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_code: 200


=== TEST 12c: Max-stale request fails as items are properly deleted
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_12_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_12 {
    content_by_lua_block {
        ngx.print("ORIGIN: ", ngx.req.get_uri_args()["a"])
    }
}
--- more_headers
Cache-Control: max-stale=1000
--- request eval
[ "GET /purge_cached_12_prx?a=1", "GET /purge_cached_12_prx?a=2" ]
--- no_error_log
[error]
--- response_body eval
[ "ORIGIN: 1", "ORIGIN: 2" ]


=== TEST 13a: Prime two keys and break them
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        local sabotage = ngx.req.get_uri_args()["sabotage"]
        if sabotage then
            -- Set query string to match original request
            ngx.req.set_uri_args({a=1})

            local redis = require("ledge").create_redis_connection()
            local handler = require("ledge").create_handler()
            handler.redis = redis
            local key_chain = handler:cache_key_chain()

            if sabotage == "uri" then
                redis:hdel(key_chain.main, "uri")
                ngx.print("Sabotaged: uri")
            elseif sabotage == "body" then
                handler.storage = require("ledge").create_storage_connection()

                handler.storage:delete(redis:hget(key_chain.main, entity))

                ngx.print("Sabotaged: body storage")
            end
        else
            require("ledge").create_handler():run()
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
[ "GET /purge_cached_13_prx?a=1",
"GET /purge_cached_13_prx?a=2",
"GET /purge_cached_13_prx?a=1&sabotage=body",
"GET /purge_cached_13_prx?a=1&sabotage=uri" ]
--- no_error_log
[error]
--- response_body_like eval
[ "TEST 13: 1 primed",
 "TEST 13: 2 primed",
 "Sabotaged: body storage",
 "Sabotaged: uri" ]


=== TEST 13b: Wildcard purge broken entry with X-Purge: revalidate
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_13_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
    body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
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
--- error_log
TEST 13 Revalidated: 2 primed
--- response_body_like
purge_mode: revalidate
qless_jobs.1.jid: [a-f0-9]{32}
qless_jobs.1.klass: ledge.jobs.purge
qless_jobs.1.options.jid: [a-f0-9]{32}
qless_jobs.1.options.priority: 5
qless_jobs.1.options.tags.1: purge
result: scheduled
--- error_code: 200


=== TEST 14: Purge API runs
--- http_config eval: $::HttpConfig
--- config
location /purge_api {
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_14_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_14 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 14: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
[
"GET /purge_cached_14_prx?a=1", "GET /purge_cached_14_prx?a=2",

qq(PURGE /purge_api
{"uris": ["http://localhost:$LedgeEnv::nginx_port/purge_cached_14_prx?a=1", "http://localhost:$LedgeEnv::nginx_port/purge_cached_14_prx?a=2"]}),

"GET /purge_cached_14_prx?a=1", "GET /purge_cached_14_prx?a=2",
]
--- more_headers eval
[
"","",
"Content-Type: Application/JSON",
"","",
]
--- response_body eval
[
"TEST 14: 1", "TEST 14: 2",

qq(purge_mode: invalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_14_prx?a=1.result: purged
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_14_prx?a=2.result: purged
),

"TEST 14: 1", "TEST 14: 2",
]
--- response_headers_like eval
[
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
"Content-Type: application/json",
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
]
--- no_error_log
[error]


=== TEST 15: Purge API wildcard query string
--- http_config eval: $::HttpConfig
--- config
location /purge_api {
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_15_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
    require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_15 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 15: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
[
"GET /purge_cached_15_prx?a=1", "GET /purge_cached_15_prx?a=2",

qq(PURGE /purge_api
{"uris": ["http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx?a*"]}),
]
--- more_headers eval
[
"","",
"Content-Type: Application/JSON",
]
--- response_body_like eval
[
"TEST 15: 1", "TEST 15: 2",

qq(purge_mode: invalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.qless_jobs.1.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.qless_jobs.1.klass: ledge.jobs.purge
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.qless_jobs.1.options.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.qless_jobs.1.options.priority: 5
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.qless_jobs.1.options.tags.1: purge
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_15_prx\\?a\\*.result: scheduled
),
]
--- response_headers_like eval
[
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
"Content-Type: application/json",
]
--- wait: 2
--- no_error_log
[error]

=== TEST 15b: Purge API wildcard query string
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_15_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
    require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_15 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 15b: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
["GET /purge_cached_15_prx?a=1", "GET /purge_cached_15_prx?a=2"]
--- response_body_like eval
["TEST 15b: 1", "TEST 15b: 2"]
--- response_headers_like eval
["X-Cache: MISS from .+", "X-Cache: MISS from .+"]
--- no_error_log
[error]

=== TEST 16: Purge API wildcards
--- http_config eval: $::HttpConfig
--- config
location /purge_api {
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_16_prx {
    rewrite ^(.*)_prx(.*)? $1$2 break;
    content_by_lua_block {
    require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 16: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
[
"GET /purge_cached_16_prx?a=1", "GET /purge_cached_16_prx?a=2",

qq(PURGE /purge_api
{"uris": ["http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx*"]}),
]
--- more_headers eval
[
"","",
"Content-Type: Application/JSON",
]
--- response_body_like eval
[
"TEST 16: 1", "TEST 16: 2",

qq(purge_mode: invalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.qless_jobs.1.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.qless_jobs.1.klass: ledge.jobs.purge
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.qless_jobs.1.options.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.qless_jobs.1.options.priority: 5
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.qless_jobs.1.options.tags.1: purge
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_16_prx\\*.result: scheduled
),
]
--- response_headers_like eval
[
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
"Content-Type: application/json",
]
--- wait: 2
--- no_error_log
[error]

=== TEST 16b: Purge API wildcard check
--- http_config eval: $::HttpConfig
--- config
location /purge_cached_16_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
    require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_16 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 16b: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
["GET /purge_cached_16_prx?a=1", "GET /purge_cached_16_prx?a=2"]
--- response_body_like eval
["TEST 16b: 1", "TEST 16b: 2"]
--- response_headers_like eval
["X-Cache: MISS from .+", "X-Cache: MISS from .+"]
--- no_error_log
[error]

=== TEST 17: Purge API - bad request
--- http_config eval: $::HttpConfig
--- config
location /purge_api {
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}

--- request eval
[
'PURGE /purge_api
{"uris": ["foobar"]}',

'PURGE /purge_api
this is not valid json',

'PURGE /purge_api
{"foo": ["bar"]}',

'PURGE /purge_api
{"uris": []}',

'PURGE /purge_api
{"uris": "not an array"}',

'PURGE /purge_api
{"uris": ["http://www.example.com/"], "purge_mode": "foobar"}'
]
--- more_headers
Content-Type: Application/JSON
--- error_code eval
[200,400,400,400,400,400]
--- response_body eval
[
"purge_mode: invalidate
result.foobar.error: bad uri: foobar
",
"error: Could not parse request body: Expected value but found invalid token at character 1
",
"error: No URIs provided
",
"error: No URIs provided
",
"error: Field 'uris' must be an array
",
"error: Invalid purge_mode
",
]
--- no_error_log
[error]


=== TEST 17: Purge API passes through purge_mode
--- http_config eval: $::HttpConfig
--- config
location /purge_api {
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_17_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_17 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.print("TEST 17: ", ngx.req.get_uri_args()["a"])
    }
}
--- request eval
[
"GET /purge_cached_17_prx?a=1",

qq(PURGE /purge_api
{"purge_mode": "revalidate", "uris": ["http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx?a=1"]}),
]
--- more_headers eval
[
"", "Content-Type: Application/JSON",
]
--- response_body_like eval
[
"TEST 17: 1",

qq(purge_mode: revalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.qless_jobs.1.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.qless_jobs.1.klass: ledge.jobs.revalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.qless_jobs.1.options.jid: [a-f0-9]{32}
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.qless_jobs.1.options.priority: 4
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.qless_jobs.1.options.tags.1: revalidate
result.http://localhost:$LedgeEnv::nginx_port/purge_cached_17_prx\\?a=1.result: purged
),

]
--- wait: 1

=== TEST 18: Purge clears all representations
--- http_config eval: $::HttpConfig
--- config
location /purge {
    rewrite ^ /purge_cached_18 break;
    content_by_lua_block {
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_18_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_18 {
    content_by_lua_block {
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["Vary"] = "X-Test"
        ngx.print("TEST 18: ", ngx.req.get_headers()["X-Test"])
    }
}
--- request eval
[
"GET /purge_cached_18_prx", "GET /purge_cached_18_prx",

"PURGE /purge",

"GET /purge_cached_18_prx", "GET /purge_cached_18_prx",
]
--- more_headers eval
[
"X-Test: abc", "X-Test: xyz",
"",
"X-Test: abc", "X-Test: xyz",
]
--- response_body eval
[
"TEST 18: abc", "TEST 18: xyz",

"purge_mode: invalidate
result: purged
",

"TEST 18: abc", "TEST 18: xyz",
]
--- response_headers_like eval
[
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
"",
"X-Cache: MISS from .+", "X-Cache: MISS from .+",
]
--- no_error_log
[error]

=== TEST 19: Purge response with no body
--- http_config eval: $::HttpConfig
--- config
location /purge {
    rewrite ^ /purge_cached_19 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(true)
        require("ledge").create_handler():run()
    }
   body_filter_by_lua_block {
        ngx.arg[1] = format_json(ngx.arg[1])
        ngx.arg[2] = true
    }
}
location /purge_cached_19_prx {
    rewrite ^(.*)_prx$ $1 break;
    content_by_lua_block {
        require("ledge.state_machine").set_debug(false)
        require("ledge").create_handler({
            keep_cache_for = 3600,
        }):run()
    }
}
location /purge_cached_19 {
    content_by_lua_block {
        local incr = ngx.shared.ledge_test:incr("test19", 1, 0)
        ngx.header["Cache-Control"] = "max-age=3600"
        ngx.header["X-Incr"] = incr
    }
}
--- request eval
[
"GET /purge_cached_19_prx", "GET /purge_cached_19_prx",

"PURGE /purge",

"GET /purge_cached_19_prx"
]
--- error_code eval
[200, 200, 200, 200]
--- response_headers_like eval
[
"X-Cache: MISS from .+
X-Incr: 1",

"X-Cache: HIT from .+
X-Incr: 1",

"",

"X-Cache: MISS from .+
X-Incr: 2"
]
--- no_error_log
[error]
