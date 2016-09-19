# Ledge

A [Lua](http://www.lua.org) module for [OpenResty](http://openresty.org), providing ESI capable HTTP cache
functionality, backed by [Redis](http://redis.io).

## Table of Contents

* [Status](#status)
* [Features](#features)
* [Installation](#installation)
* [Configuration options](#configuration-options)
    * [origin_mode](#origin_mode)
    * [upstream_connect_timeout](#upstream_connect_timeout)
    * [upstream_read_timeout](#upstream_read_timeout)
    * [upstream_host](#upstream_host)
    * [upstream_port](#upstream_port)
    * [upstream_use_ssl](#upstream_use_ssl)
    * [upstream_ssl_server_name](#upstream_ssl_server_name)
    * [upstream_ssl_verify](#upstream_ssl_verify)
    * [use_resty_upstream](#use_resty_upstream)
    * [resty_upstream](#resty_upstream)
    * [buffer_size](#buffer_size)
    * [cache_max_memory](#cache_max_memory)
    * [advertise_ledge](#advertise_ledge)
    * [redis_database](#redis_database)
    * [redis_qless_database](#redis_qless_database)
    * [redis_connect_timeout](#redis_connect_timeout)
    * [redis_read_timeout](#redis_read_timeout)
    * [redis_keepalive_timeout](#redis_keepalive_timeout)
    * [redis_keepalive_poolsize](#redis_keepalive_poolsize)
    * [redis_host](#redis_host)
    * [redis_use_sentinel](#redis_use_sentinel)
    * [redis_sentinel_master_name](#redis_sentinel_master_name)
    * [redis_sentinels](#redis_sentinels)
    * [keep_cache_for](#keep_cache_for)
    * [minimum_old_entity_download_rate](#minimum_old_entity_download_rate)
    * [max_stale](#max_stale)
    * [stale_if_error](#stale_if_error)
    * [cache_key_spec](#cache_key_spec)
    * [enable_collapsed_forwarding](#enable_collapsed_forwarding)
    * [collapsed_forwarding_window](#collapsed_forwarding_window)
    * [esi_enabled](#esi_enabled)
    * [esi_content_types](#esi_content_types)
    * [esi_allow_surrogate_delegation](#esi_allow_surrogate_delegation)
    * [esi_recursion_limit](#esi_recursion_limit)
    * [esi_pre_include_callback](#esi_pre_include_callback)
    * [esi_args_prefix](#esi_args_prefix)
    * [gunzip_enabled](#gunzip_enabled)
    * [keyspace_scan_count](#keyspace_scan_count)
    * [revalidate_parent_headers](#revalidate_parent_headers)
* [Workers](#workers)
    * [run_workers](#run_workers)
* [Events](#events)
    * [bind](#bind)
* [Event types](#event-types)
    * [cache_accessed](#cache_accessed)
    * [origin_required](#origin_required)
    * [before_request](#before_request)
    * [origin_fetched](#origin_fetched)
    * [before_save](#before_save)
    * [response_ready](#response_ready)
    * [set_revalidation_headers](#set_revalidation_headers)
* [Protecting purge requests](#protecting-purge-requests)
* [Logging](#logging)
* [Licence](#licence)


## Status

Under active development, functionality may change without much notice. However, release branches are
generally well tested in staging environments against real world sites before being tagged, and the latest tagged
release is guaranteed to be running hundreds of sites worldwide.

Please feel free to ask questions / raise issues / request features at
[https://github.com/pintsized/ledge/issues](https://github.com/pintsized/ledge/issues).


## Features

### RFC compliant HTTP reverse proxy caching

In general the aim has been to be as compliant as possible, providing enough options / hooks to deal
with real world cases. This includes full end-to-end revalidation (specified and unspecified) semantics
and so on.

There are exceptions and omissions. Please raise an [an issue](https://github.com/pintsized/ledge/issues)
if something doesn't work as expected.


### High availability

Support for Redis [Sentinel](http://redis.io/topics/sentinel) is fully integrated, making it possible
to run master / slave pairs, where Sentinel promotes the slave to master in the event of failure, without
losing cache. Cache reads will be served from the slave in the window between the master failing and the
slave being promoted.

Upstreams can be load balanced using [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream),
and there are two [offline modes](#origin_mode) to either bypass a failing origin or "avoid" it, serving stale
cache where possible.


### Advanced caching behaviours

#### Collapsed forwarding

Concurrent similar requests can be [collapsed](#enable_collapsed_forwarding) into single upstream requests
to reduce load at the origin. 

#### Stale / background revalidation

There is support for intentionally serving stale content in the event of upstream errors, or even for a pre-determined
"additional TTL" whilst revalidating in the background. For example, if your cache TTL is 24 hours, consider
changing this to 1 hour, and specifying `max_stale` as 23 hours. The net TTL is thus the same, but requests
after the first hour will serve a cache HIT and then trigger a background revalidation of the content, extending
the TTL for a further 1 hour + 23 hours stale.


### PURGE

Cache can be invalidating using the PURGE method. This will return a status of `200` indicating
success, or `404` if there was nothing to purge. In addition, a JSON response body is returned with more
information.

`$> curl -X PURGE -H "Host: example.com" http://cache.example.com/page1 | jq .`
```json
{
  "purge_mode": "invalidate",
  "result": "nothing to purge"
}
```

In addtion, PURGE requests accept an `X-Purge` request header, to alter the purge mode. Supported values
are `invalidate` (default), `delete` (to actually hard remove the item and all metadata), and `revalidate`.


#### Revalidate-on-purge

When specifying `X-Purge: revalidate`, a JSON response is returned detailing a background
[Qless](https://github.com/pintsized/lua-resty-qless) job ID scheduled to revalidate the cache item.
Note that `X-Cache: revalidate, delete` has no useful meaning beacause revalidation requires metadata
to be present (`delete` overrides).

`$> curl -X PURGE -H "X-Purge: revalidate" -H "Host: example.com" http://cache.example.com/page1 | jq .`

```json
{
  "purge_mode": "revalidate",
  "qless_job": {
    "options": {
      "priority": 4,
      "jid": "5eeabecdc75571d1b93e9c942dfcebcb",
      "tags": [
        "revalidate"
      ]
    },
    "jid": "5eeabecdc75571d1b93e9c942dfcebcb",
    "klass": "ledge.jobs.revalidate"
  },
  "result": "already expired"
}
```

#### Wildcard PURGE

Wildcard (*) patterns are also supported in URIs, which will always return a status of `200` and a JSON
body detailing a background job ID. Wildcard purges involve scanning the entire keyspace, and so can take
a little while. See [keyspace_scan_count](#keyspace_scan_count) for tuning help.

In addtion, the `X-Purge` request header will propogate to all URIs purged as a result of the wildcard,
making it possible to trigger site / section wide revalidation for example. Again, be careful what you
wish for.

`$> curl -v -X PURGE -H "X-Purge: revalidate" -H "Host: example.com" http://cache.example.com/* | jq .`

```json
{
  "purge_mode": "revalidate",
  "qless_job": {
    "options": {
      "priority": 5,
      "jid": "b2697f7cb2e856cbcad1f16682ee20b0",
      "tags": [
        "purge"
      ]
    },
    "jid": "b2697f7cb2e856cbcad1f16682ee20b0",
    "klass": "ledge.jobs.purge"
  },
  "result": "scheduled"
}
```

### Edge Side Includes (ESI)

Almost complete support for the [ESI 1.0 Language Specification](https://www.w3.org/TR/esi-lang) is
included, with a few exceptions, and a few enhancements.

```html
<html>
<esi include="/header" />
<body>

   <esi:choose>
      <esi:when test="$(QUERY_STRING{foo}) == 'bar'">
         Hi
      </esi:when>
      <esi:otherwise>
         <esi:choose>
            <esi:when test="$(HTTP_COOKIE{mycookie}) == 'yep'">
               Yep
            </esi:when>
         </es:choose>
      </esi:otherwise>
   </esi:choose>
   
</body>
</html>
```

#### Enabling ESI

Note that simply [enabling](#esi_enabled) ESI might not be enough. We also check the
[content type](#esi_content_types) against the allowed types specified, but more importantly ESI processing
is contingent upon the [Edge Architecture Specification](https://www.w3.org/TR/edge-arch/). When enabled,
Ledge will advertise capabilities upstream with the `Surrogate-Capability` request header, and expect
the origin to include a `Surrogate-Control` header delegating ESI processing to Ledge.

If your origin is not ESI aware, a common approach is to bind to the [origin_fetched](#origin_fetched)
event in order to add the `Surrogate-Control` header manually. E.g.

```lua
local function set_surrogate_response_header(res)
    -- Don't enable ESI on redirect responses
    -- Don't override Surrogate Control if it already exists
    local status = res.status
    if not res.header["Surrogate-Control"] and not (status > 300 and status < 303) then
        res.header["Surrogate-Control"] = 'content="ESI/1.0"'
    end
end
ledge:bind("origin_fetched", set_surrogate_response_header)
```

#### Regular expressions in conditions

In addition to the operators defined in the [ESI specification](https://www.w3.org/TR/esi-lang), we also
support regular expressions in conditions, using the Perl-ish operator `=~`.

```html
<esi:choose>
   <esi:when test="$(QUERY_STRING{name}) =~ '/james|john/i'">
      Hi James or John
   </esi:when>
</esi:choose>
```

#### Custom variables

In addition to the variables defined in the [ESI specification](https://www.w3.org/TR/esi-lang), it is possible
to stuff custom variables into a special table before running Ledge. A common use case is to combine the
[Geo IP](http://nginx.org/en/docs/http/ngx_http_geoip_module.html) module varibles for use in ESI conditions.

```lua
content_by_lua_block {
   ngx.ctx.ledge_esi_custom_variables = {
      messages = {
         foo = "bar",
      }
   }
   ledge:run()
}
```

```html
<esi:vars>$(MESSAGES{foo})</esi:vars>
```

#### ESI Args

ESI args are query string parameters identified by a configurable prefix, which defaults to `esi_`. With ESI enabled,
query string parameters with this prefix are removed from the cache key and also from upstream requests, and instead
stuffed into the `$(ESI_ARGS{foo})` variable for use in ESI, typically in conditions.

This has the effect of allowing query string parameters to alter the page layout without splitting the cache,
since variables are used exclusively by the ESI processor, downstream of cache.

`$> curl -H "Host: example.com" http://cache.example.com/page1?esi_display_mode=summary`

```html
<esi:choose>
   <esi:when test="$(ESI_ARGS{display_mode} == 'summary'">
      <!-- SUMMARY -->
   </esi:when>
   <esi:when test="$(ESI_ARGS{display_mode} == 'details'">
      <!-- DETAILS -->
   </esi:when>
</esi:choose>
```

In this example, the `esi_display_mode` values of `summary` or `details` will return the same cache HIT, but
display different content.

#### Missing ESI features

The following parts of the [ESI specification](https://www.w3.org/TR/esi-lang) are not supported,
but could be in due course if a need is identified.

* `<esi:inline>` not implemented (or advertised as a capability).
* No support for the onerror or alt attributes for `<esi:include>`. Instead, we "continue" on error by default.
* `<esi:try | attempt | except>` not implemented.
* The "dictionary (special)" substructure variable type for `HTTP_USER_AGENT` is not implemented.


### Miscellaneous

Other features include:

* Cache key can be flexibly configured for tuning cache HIT rates (e.g. dropping querystring tracking args).
* 100% streaming architecture for predictable memory usage, even when processing ESI instructions.
* Configurable [max memory](#cache_max_memory) limits for body entities.
* [Event hooks](#events) to override cache policies at various stages using Lua script.
* Caching POST responses (serve-able to subsequent GET / HEAD requests).
* Stores gzipped responses and dynamically gunzip when Accept-Encoding: gzip is not present.


## Installation

Download and install:

* [OpenResty](http://openresty.org/) >= 1.9.x
* [Redis](http://redis.io/download) >= 2.8.x

Review the [lua-nginx-module](https://github.com/openresty/lua-nginx-module) documentation on how to
run Lua code in Nginx. If you are new to OpenResty, it's important to take the time to do this
properly, as the environment is quite specific. Note that LuaJIT must be enabled (which is the default).

Clone this repo, and the following dependencies into a path defined by
[lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path):

* [lua-resty-http](https://github.com/pintsized/lua-resty-http) >= 0.09
* [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector) >= 0.03
* [lua-resty-qless](https://github.com/pintsized/lua-resty-qless) >= 0.07
* [lua-resty-cookie](https://github.com/cloudflare/lua-resty-cookie)
* [lua-ffi-zlib](https://github.com/hamishforbes/lua-ffi-zlib) >= 0.01

Enable the
[lua_check_client_abort](https://github.com/openresty/lua-nginx-module#lua_check_client_abort)
directive to avoid orphaned connections to both the origin and Redis, and ensure
[if_modified_since](http://nginx.org/en/docs/http/ngx_http_core_module.html#if_modified_since) is
set to `Off`.


### Minimal configuration

A minimal configuration involves loading the module during
[init_by_lua](https://github.com/openresty/lua-nginx-module#init_by_lua), starting workers during
[init_worker_by_lua](https://github.com/openresty/lua-nginx-module#init_worker_by_lua), configuring
your upstream, and invoking Ledge during
[content_by_lua](https://github.com/openresty/lua-nginx-module#content_by_lua).

This requires that you have Redis running locally on the default port.

```nginx
nginx {
   if_modified_since Off;
   lua_check_client_abort On;
   resolver 8.8.8.8;

   lua_package_path '/path/to/lua-resty-http/lib/?.lua;/path/to/lua-resty-redis-connector/lib/?.lua;/path/to/lua-resty-qless/lib/?.lua;/path/to/lua-resty-cookie/lib/?.lua;/path/to/lua-ffi-zlib/lib/?.lua;/path/to/ledge/lib/?.lua;;';

   init_by_lua_block {
      local ledge_m = require "ledge.ledge"
      ledge = ledge_m.new()
      ledge:config_set("upstream_host", "HOST.EXAMPLE.COM")
   }

   init_worker_by_lua_block {
      ledge:run_workers()
   }

    server {
        location / {
            content_by_lua_block {
               ledge:run()
            }
        }
    }
}
```


## Configuration options

Options can be specified globally during `init_by_lua`, or for a specific server/location during
`content_by_lua`, before calling `ledge:run()`.

Config set during `content_by_lua` will only affect that specific location, and runs in the context
of the current running request. That is, you can write request-specific conditions which dynamically
set configuration for matching requests.


### origin_mode

syntax: `ledge:config_set("origin_mode", ledge.ORIGIN_MODE_NORMAL | ledge.ORIGIN_MODE_BYPASS |
ledge.ORIGIN_MODE_AVOID)`

default: `ledge.ORIGIN_MODE_NORMAL`

Determines the overall behaviour for connecting to the origin.  `ORIGIN_MODE_NORMAL` will assume the
origin is up, and connect as necessary.  `ORIGIN_MODE_AVOID` is similar to Squid's `offline_mode`,
where any retained cache (expired or not) will be served rather than trying the origin, regardless
of cache-control headers, but the origin will be tried if there is no cache to serve.
`ORIGIN_MODE_BYPASS` is the same as `AVOID`, except if there is no cache to serve we send a `503
Service Unavailable` status code to the client and never attempt an upstream connection.


### upstream_connect_timeout

syntax: `ledge:config_set("upstream_connect_timeout", 1000)`

default: `500 (ms)`

Maximum time to wait for an upstream connection (in milliseconds). If it is exceeded, we send a
`503` status code, unless [stale_if_error](#stale_if_error) is configured.


### upstream_read_timeout

syntax: `ledge:config_set("upstream_read_timeout", 5000)`

default: `5000 (ms)`

Maximum time to wait for data on a connected upstream socket (in milliseconds).  If it is exceeded,
we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.


### upstream_host

syntax: `ledge:config_set("upstream_host", "web01.example.com")`

default: `empty (must be set)`

Specifies the hostname or IP address of the upstream host. If a hostname is specified, you must
configure the Nginx [resolver](http://nginx.org/en/docs/http/ngx_http_core_module.html#resolver)
somewhere, for example:

```nginx
resolver 8.8.8.8;
```


### upstream_port

syntax: `ledge:config_set("upstream_port", 80)`

default: `80`

Specifies the port of the upstream host.


### upstream_use_ssl

syntax: `ledge:config_set("upstream_use_ssl", true)`

default: `false`

Toggles the use of SSL on the upstream connection. Other `upstream_ssl_*` options will be ignored if
this is not set to `true`.


### upstream_ssl_server_name

syntax: `ledge:config_set("upstream_ssl_server_name", "www.example.com")`

default: `nil`

Specifies the SSL server name used for Server Name Indication (SNI). See
[sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more
information.


### upstream_ssl_verify

syntax: `ledge:config_set("upstream_ssl_verify", true)`

default: `false`

Toggles SSL verification. See
[sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more
information.


### use_resty_upstream

syntax: `ledge:config_set("use_resty_upstream", true)`

default: `false`

Toggles whether to use a preconfigured
[lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) instance (see below),
instead of the above `upstream_*` options.


### resty_upstream

syntax: `ledge:config_set("resty_upstream", my_upstream)`

default: `nil`

Specifies a preconfigured [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream)
instance to be used for all upstream connections. This provides upstream load balancing and active
healthchecks.


### buffer_size

syntax: `ledge:config_set("buffer_size", 2^17)`

default: `2^16 (64KB in bytes)`

Specifies the internal buffer size (in bytes) used for data to be read/written/served. Upstream
responses are read in chunks of this maximum size, preventing allocation of large amounts of memory
in the event of receiving large files. Data is also stored internally as a list of chunks, and
delivered to the Nginx output chain buffers in the same fashion.

The only exception is if ESI is configured, and Ledge has determined there are ESI instructions to
process, and any of these instructions span a given chunk.  In this case, buffers are concatenated
until a complete instruction is found, and then ESI operates on this new buffer.


### cache_max_memory

syntax: `ledge:config_set("cache_max_memory", 4096)`

default: `2048 (KB)`

Specifies (in kilobytes) the maximum size a cache item can occupy before we give up attempting to
store (and delete the entity).

Note that since entities are written and served as a list of buffers, when replacing an entity we
create a new entity list and only delete the old one after existing read operations should have
completed, marking the old entity for garbage collection.

As a result, it is possible for multiple entities for a given cache key to exist, each up to a
maximum of `cache_max_memory`. However this should only every happen quite temporarily, the timing
of which is configurable with [minimum_old_entity_download_rate](#minimum_old_entity_download_rate).


### advertise_ledge

syntax: `ledge:config_set("advertise_ledge", false)`

default `true`

If set to false, disables advertising the software name and version eg `(ledge/1.00)` from the `Via`
response header.


### redis_database

syntax: `ledge:config_set("redis_database", 1)`

default: `0`

Specifies the Redis database to use for cache data / metadata.


### redis_qless_database

syntax: `ledge:config_set("redis_qless_database", 2)`

default: `1`

Specifies the Redis database to use for
[lua-resty-qless](https://github.com/pintsized/lua-resty-qless) jobs. These are background tasks
such as garbage collection and revalidation, which are managed by Qless. It can be useful to keep
these in a separate database, purely for namespace sanity.


### redis_connect_timeout

syntax: `ledge:config_set("redis_connect_timeout", 1000)`

default: `500 (ms)`

Maximum time to wait for a Redis connection (in milliseconds). If it is exceeded, we send a `503`
status code, unless.


### redis_read_timeout

syntax: `ledge:config_set("redis_read_timeout", 5000)`

default: `5000 (ms)`

Maximum time to wait for data on a connected Redis socket (in milliseconds). If it is exceeded, we
send a `503` status code.


### redis_keepalive_timeout

syntax: `ledge:config_set("redis_keepalive_timeout", 120)`

default: `60s or lua_socket_keepalive_timeout (sec)`


### redis_keepalive_poolsize

syntax: `ledge:config_set("redis_keepalive_poolsize", 60)`

default: `Defaults to 30 or lua_socket_pool_size`


### redis_host

`syntax: ledge:config_set("redis_host", { host = "127.0.0.1", port = 6380 })`

`default: { host = "127.0.0.1", port = 6379, password = nil, socket = nil }`

Specifies the Redis host to connect to. If `socket` is specified then `host` and `port` are ignored.
See the [lua-resty-redis](https://github.com/openresty/lua-resty-redis#connect) documentation for
more details.


### redis_use_sentinel

syntax: `ledge:config_set("redis_use_sentinel", true)`

default: `false`

Toggles the use of [Redis Sentinel](http://redis.io/topics/sentinel) for Redis host discovery. If
set to `true`, then [redis_sentinels](#redis_sentinels) will override [redis_host](#redis_host).


### redis_sentinel_master_name

syntax: `ledge:config_set("redis_sentinel_master_name", "master")`

default: `mymaster`

Specifies the [Redis Sentinel](http://redis.io/topics/sentinel) master name.


### redis_sentinels

`syntax: ledge:set_config("redis_sentinels", { { host = "127.0.0.1", port = 6381 }, { host =
"127.0.0.1", port = 6382 }, { host = "127.0.0.1", port = 6383 }, }`

default: `nil`

Specifies a list of [Redis Sentinels](http://redis.io/topics/sentinel) to be tried in order. Once
connected, Sentinel provides us with a master Redis node to connect to. If it cannot identify a
master, or if the master node cannot be connected to, we ask Sentinel for a list of slaves to try.
This normally happens when the master has gone down, but Sentinel has not yet promoted a slave.
During this window, we optimistically try to connect to a slave for read-only operations, since
cache-hits may still be served.


### keep_cache_for

syntax: `ledge:config_set("keep_cache_for", 86400 * 14)`

default: `86400 * 30 (1 month in seconds)`

Specifies how long to retain cache data past its expiry date. This allows us to serve stale cache in
the event of upstream failure with [stale_if_error](#stale_if_error) or [origin_mode](#origin_mode)
settings.

Items will be evicted when under memory pressure provided you are using one of the Redis [volatile
eviction policies](http://redis.io/topics/lru-cache), so there should generally be no real need to
lower this for space reasons.

Items at the extreme end of this (i.e. nearly a month old) are clearly very rarely requested, or
more likely, have been removed at the origin.


### minimum_old_entity_download_rate

syntax: `ledge:config_set("minimum_old_entity_download_rate", 128)`

default: `56 (kbps)`

Clients reading slower than this who are also unfortunate enough to have started reading from an
entity which has been replaced (due to another client causing a revalidation for example), may have
their entity garbage collected before they finish, resulting in an incomplete resource being
delivered.

Lowering this is fairer on slow clients, but widens the potential window for multiple old entities
to stack up, which in turn could threaten Redis storage space and force evictions.

This design favours high availability (since there are no read-locks, we can serve cache from Redis
slaves in the event of failure) on the assumption that the chances of this causing incomplete
resources to be served are quite low.


### max_stale

syntax: `ledge:config_set("max_stale", 300)`

default: `nil`

Specifies, in seconds, how far past expiry we can serve cached content. If a value is specified by
the `Cache-Control: max-stale=xx` request header, then this setting is ignored, placing control in
the client's hands.

This setting is useful for serving expensive content stale whilst revalidating in the background.
For example, if some content has a TTL of one hour, you may wish to change this to 45 minutes, and
allow stale serving for 15 minutes. Thus the cache item has the same effective TTL, but any requests
in the last 15 minutes will be served quickly, and trigger a background revalidation for the latest
version.

**WARNING:** Any setting other than `nil` may violate the HTTP specification (i.e. if the client
does not override it with a valid request header value).


### stale_if_error

syntax: `ledge:config_set("stale_if_error", 86400)`

default: `nil`

Specifies, in seconds, how far past expiry to serve stale cached content if the origin returns an
error.

This can be overriden by the request using the [stale-if-error](http://tools.ietf.org/html/rfc5861)
Cache-Control extension.


### cache_key_spec

`syntax: ledge:config_set("cache_key_spec", { ngx.var.host, ngx.var.uri, ngx.var.args })`

`default: { ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }`

Specifies the cache key format. This allows you to abstract certain items for great hit rates (at
the expense of collisions), for example.

The default spec is:

```lua
{ ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }
```

Which will generate cache keys in Redis such as:

```
ledge:cache_obj:http:example.com:/about
ledge:cache_obj:http:example.com:/about:p=2&q=foo
```

If you're doing SSL termination at Nginx and your origin pages look the same for HTTPS and HTTP
traffic, you could  provide a cache key spec omitting `ngx.var.scheme`, to avoid splitting the cache
when the content is identical.


### enable_collapsed_forwarding

syntax: `ledge:config_get("enable_collapsed_forwarding", true)`

default: `false`

With collapsed forwarding enabled, Ledge will attempt to collapse concurrent origin requests for
known (previously) cacheable resources into single upstream requests.

This is useful in reducing load at the origin if requests are expensive. The longer the origin
request, the more useful this is, since the greater the chance of concurrent requests.

Ledge wont collapse requests for resources that it hasn't seen before and weren't cacheable last
time. If the resource has become non-cacheable since the last request, the waiting requests will go
to the origin themselves (having waited on the first request to find this out).


### collapsed_forwarding_window

syntax: `ledge:config_set("collapsed_forwarding_window", 30000)`

default: `60000 (ms)`

When collapsed forwarding is enabled, if a fatal error occurs during the origin request, the
collapsed requests may never receive the response they are waiting for. This setting puts a limit on
how long they will wait, and how long before new requests will decide to try the origin for
themselves.

If this is set shorter than your origin takes to respond, then you may get more upstream requests
than desired. Fatal errors (server reboot etc) may result in hanging connections for up to the
maximum time set. Normal errors (such as upstream timeouts) work independently of this setting.


### esi_enabled

syntax: `ledge:config_set("esi_enabled", true)`

default: `false`

Toggles [ESI](http://www.w3.org/TR/esi-lang) scanning and processing, though behaviour is also
contingent upon [esi_content_types](#esi_content_types) and
[esi_surrogate_delegation](#esi_surrogate_delegation) settings, as well as `Surrogate-Control` /
`Surrogate-Capability` headers.

ESI instructions are detected on the slow path (i.e. when fetching from the origin), so only
instructions which are known to be present are processed on cache HITs.

All features documented in the [ESI 1.0 Language Specification](http://www.w3.org/TR/esi-lang) are
supported, with the following exceptions:

* `<esi:inline>` not implemented (or advertised as a capability).
* No support for the `onerror` or `alt` attributes for `<esi:include>`. Instead, we "continue" on error by default.
* `<esi:try | attempt | except>` not implemented.
* The "dictionary (special)" substructure variable type for `HTTP_USER_AGENT` is not implemented.


### esi_content_types

syntax: `ledge:config_set("esi_content_types", { "text/html", "text/javascript" })`

default: `{ text/html }`

Specifies content types to perform ESI processing on. All other content types will not be considered
for processing.


### esi_allow_surrogate_delegation

syntax: `ledge:config_set("esi_allow_surrogate_delegation", true)`

default: false

[ESI Surrogate Delegation](http://www.w3.org/TR/edge-arch) allows for downstream intermediaries to
advertise a capability to process ESI instructions nearer to the client. By setting this to `true`
any downstream offering this will disable ESI processing in Ledge, delegating it downstream.

When set to a Lua table of IP address strings, delegation will only be allowed to this specific
hosts. This may be important if ESI instructions contain sensitive data which must be removed.


### esi_recursion_limit

syntax: `ledge:config_set("esi_recursion_limit", 5)`

default: 10

Limits fragment inlusion nesting, to avoid accidental infinite recursion.


### esi_pre_include_callback

syntax: `ledge:config_set("esi_pre_include_callback", function(req_params) ... end)`

default: nil

A function provided here will be called each time the ESI parser goes to make an outbound HTTP request
for a fragment. The request parameters are passed through and can be manipulated here, for example
to modify request headers.


### esi_args_prefix

syntax: `ledge:config_set("esi_args_prefix", "__esi_")`

default: "esi_"

URI args prefix for parameters to be ignored from the cache key (and not proxied upstream), for use
exclusively with ESI rendering logic. Set to nil to disable the feature.


### gunzip_enabled

syntax: `ledge:config_set("gunzip_enabled", false)`

default: true

With this enabled, gzipped responses will be uncompressed on the fly for clients that do not set
`Accept-Encoding: gzip`. Note that if we receive a gzipped response for a resource containing ESI instructions,
we gunzip whilst saving and store uncompressed, since we need to read the ESI instructions.

Also note that `Range` requests for gzipped content must be ignored - the full response will be returned.


### keyspace_scan_count

syntax: `ledge:config_set("keyspace_scan_count", 10000)`

default: 1000

Tunes the behaviour of keyspace scans, which occur when sending a PURGE request with wildcard syntax.
A higher number may be better if latency to Redis is high and the keyspace is large.

### revalidate_parent_headers

syntax: `ledge:config_set("revalidate_parent_headers", {"x-real-ip", "authorization"})`

default: {"authorization", "cookie"}

Defines which headers from the parent request are passed through to a background revalidation.
Useful when upstreams require authentication.

## Workers

Ledge uses [qless](https://github.com/seomoz/qless-core) and the
[lua-resty-qless](https://github.com/pintsized/lua-resty-qless) binding for scheduling background
tasks, managed by Redis.

Currently, there is only one job type, which is the garbage collection job for replaced entities,
and it is imperative that this runs.


### run_workers

syntax: `init_worker_by_lua 'ledge:run_workers(options)';`

default options: `{ interval = 10, concurrency = 1 }`

Starts the Ledge workers within each Nginx worker process. When no jobs are left to be processed,
each worker will wait for `interval` before checking again.

You can have many worker "light threads" per worker process, by upping the concurrency. They will
yield to each other when doing i/o.

The default options are quite conservative. You probably want to up the `concurrency` and lower the
`interval` on busy systems.



## Events

Events are broadcast at various stages, which can be listened for using Lua functions. A response
table is passed through to your function, providing the opportunity to manipulate the response as
needed.

For example, this may be useful if an upstream doesn't set optimal `Cache-Control` headers, and
cannot be easily be modified itself.

Note that the response body itself is not available, since this is streamed at the point of serving.

Example:

```lua
ledge:bind("origin_fetched", function(res)
    -- Add some cache headers.  Ledge will assume they came from the origin.
    res.header["Cache-Control"] = "max-age=" .. 86400
    res.header["Last-Modified"] = ngx.http_time(ngx.time())
end)
```

Note that the creation of closures in Lua can be kinda expensive, so you may wish to put these
functions in a module and pass them through.


### bind

syntax: `ledge:bind(event_name, callback)`

Binds a user defined function to an event.


## Event types

### cache_accessed

syntax: `ledge:bind("cache_accessed", function(res) -- end)`

params: `res` The cached response table (does not include the body).

Fires directly fter the response was successfully loaded from cache.


### origin_required

syntax: `ledge:bind("origin_required", function() -- end)`

params: `nil`

Fires when decided we need to request from the origin.


### before_request

syntax: `ledge:bind("before_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to send to the
[httpc:request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform an origin request.


### origin_fetched

syntax: `ledge:bind("origin_fetched", function(res) -- end)`

params: `res`. The response table (does not include the body).

Fires when the status/headers have been fetched, but before it is stored. Typically used to override
cache headers before we decide what to do with this response. Note unlike `before_save` below, this
fires for all fetched content, not just cacheable content.


## before_save

syntax: `ledge:bind("before_save", function(res) -- end)`

params: `res`. The response table (does not include the body).

Fires when we're about to save the response.


## response_ready

syntax: `ledge:bind("response_ready", function(res) -- end)`

params: `res`. The response table (does not include the body).

Fires when we're about to serve. Often used to modify downstream headers seperately
to the ones used to determine proxy cacheability. 



## Protecting purge requests

Ledge will respond to requests using the (fake) HTTP method `PURGE`. If the resource exists it will
be expired and Ledge will exit with `200 OK`. If the resource doesn't exists, it will exit with `404
Not Found`.

This is mostly useful for internal tools which expect to work with Squid, and you probably want to
restrict usage in some way. You can acheive this with standard Nginx configuration.

```nginx
limit_except GET POST PUT DELETE {
    allow   127.0.0.1;
    deny    all;
}
```


## set_revalidation_headers

syntax: `ledge:bind("set_revalidation_headers", function(headers) -- end)`

params: `headers`. Table of request headers.

Fires when a background revalidation is triggered.
Allows inserting and modifying the headers which are inherited by the background revalidation



## Logging

For cacheable responses, Ledge will add headers indicating the cache status.  These can be added to
your Nginx log file in the normal way.

An example using the default combined format plus the available headers:

```
    log_format ledge '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    '"Cache:$sent_http_x_cache"  "Age:$sent_http_age" "Via:$sent_http_via"'
                    ;

    access_log /var/log/nginx/access_log ledge;
```

Result:
```
   192.168.59.3 - - [23/May/2016:22:22:18 +0000] "GET /x/y/z HTTP/1.1" 200 57840 "-" "curl/7.37.1""Cache:HIT from 159e8241f519:8080"  "Age:724"
```


### X-Cache

This header follows the convention set by other HTTP cache servers. It indicates simply `HIT` or
`MISS` and the host name in question, preserving upstream values when more than one cache server is
in play. For example:

* `X-Cache: HIT from ledge.tld` A cache hit, with no (known) cache layer upstream.  `X-Cache: HIT
* from ledge.tld, HIT from proxy.upstream.tld` A cache hit, also hit upstream.  `X-Cache: MISS from
* ledge.tld, HIT from proxy.upstream.tld` A cache miss, but hit upstream.  `X-Cache: MISS from
* ledge.tld, MISS from proxy.upstream.tld` Regenerated at the origin.



## Author

James Hurst <james@pintsized.co.uk>


## Licence

This module is licensed under the 2-clause BSD license.

Copyright (c) 2016, James Hurst <james@pintsized.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted
provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and
the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions
and the following disclaimer in the documentation and/or other materials provided with the
distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
