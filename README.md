# Ledge

An [ESI](https://www.w3.org/TR/esi-lang) capable HTTP cache module for [OpenResty](http://openresty.org), backed by [Redis](http://redis.io).


## Table of Contents

* [Status](#status)
* [Features](#features)
	* [Dynamic configuration](#dynamic-configuration)
	* [Serving stale content](#serving-stale-content)
	* [PURGE API](#purge-api)
	* [Load balancing upstreams](#load-balancing-upstreams)
	* [Redis failover with Sentinel](#redis-sentinel)
	* [Collapsed forwarding](#collapsed-forwarding)
	* [Edge Side Includes](#edge-side-includes-esi)
* [Installation](#installation)
* [Configuration options](#configuration-options)
* [Binding to events](#events)
* [Background workers](#background-workers)
* [Logging](#logging)
* [Licence](#licence)


## Status

Under active development, and so functionality may change without much notice. However, release branches are generally well tested in staging environments against real world sites before being tagged, and the latest tagged release is guaranteed to be running hundreds of sites worldwide.

Please feel free to [ask questions / raise issues / request features](https://github.com/pintsized/ledge/issues).


## Features

Ledge aims to be an RFC compliant HTTP reverse proxy cache wherever possible, providing a fast and robust alternative to Squid / Varnish etc.

There are exceptions and omissions. Please raise an [issue](https://github.com/pintsized/ledge/issues) if something doesn't work as expected.

Moreover, it is particularly suited to applications where the origin is expensive or distant, making it desirable to serve from cache as optimistically as possible. For example, using [ESI](#edge-side-includes-esi) to separate page fragments where their TTL differs, serving stale content whilst [revalidating in the background](#stale--background-revalidation), [collapsing](#collapsed-forwarding) concurrent similar upstream requests, dynamically modifying the cache key specification, and [automatically revalidating](#revalidate-on-purge) content with a PURGE API.


### Dynamic configuration

Default behaviours aim to be as RFC compliant as possible, but whilst many advanced features can be [configured](#configuration-options), often in the real world it can be hard to coerce an origin server to cooperate properly with HTTP caching semantics.

By [binding to events](#events), it's possible to dynamically alter behaviours of Ledge by, for example, adjusting a given response to include a `Cache-Control` header, only when fetching from the upstream (i.e. on a cache MISS).

```lua
ledge:bind("origin_fetched", function(res)
	res.header["Cache-Control"] = "public, max-age=3600"
end)
```

### Serving stale content

Content is considered "stale" when its age is beyond its TTL. However, depending on the value of [keep_cache_for](#keep_cache_for) (which defaults to 1 month), we don't actually expire content in Redis straight away.

This allows us to implement the stale cache control extensions described in [RFC5861](https://tools.ietf.org/html/rfc5861), which provides request and response header semantics for describing how stale something can be served, when it should be revalidated in the background, and how long we can serve stale content in the event of upstream errors.

This can be very effective in ensuring a fast user experience. For example, if your content has a `max-age` of 24 hours, consider changing this to 1 hour, and adding `stale-while-revalidate` for 23 hours. The net TTL is therefore the same, but the first request after the first hour will trigger backgrounded revalidation, extending the TTL for a further 1 hour + 23 hours.

If your origin server cannot be configured in this way, you can always override by [binding](#events) to the `before_save` event.

```lua
ledge:bind("before_save", function(res)
	-- Valid for 1 hour, stale-while-revalidate for 23 hours, stale-if-error for three days
	res.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=82800, stale-if-error=259200"
end)
```

In other words, set the TTL to the highest comfortable frequency of requests at the origin, and `stale-while-revalidate` to the longest comfortable TTL, to increase the chances of background revalidation occurring. Note that the first stale request will obviously get stale content, and so very long values can result in very out of data content for one request.

All stale behaviours are constrained by normal cache control semantics. For example, if the origin is down, and the response could be served stale due to the upstream error, but the request contains `Cache-Control: no-cache` or even `Cache-Control: max-age=60` where the content is older than 60 seconds, they will be served the error, rather than the stale content.


### PURGE API

Cache can be invalidated using the PURGE method. This will return a status of `200` indicating success, or `404` if there was nothing to purge. A JSON response body is returned with more information.

`$> curl -X PURGE -H "Host: example.com" http://cache.example.com/page1 | jq .`
```json
{
  "purge_mode": "invalidate",
  "result": "nothing to purge"
}
```

In addition, PURGE requests accept an `X-Purge` request header, to alter the purge mode. Supported values are `invalidate` (default), `delete` (to actually hard remove the item and all metadata), and `revalidate`.


#### Revalidate-on-purge

When specifying `X-Purge: revalidate`, a JSON response is returned detailing a background
[Qless](https://github.com/pintsized/lua-resty-qless) job ID scheduled to revalidate the cache item.

Note that `X-Cache: revalidate, delete` has no useful meaning because revalidation requires metadata to be present (`delete` overrides).

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

Wildcard (*) patterns are also supported in URIs, which will always return a status of `200` and a JSON body detailing a background job ID. Wildcard purges involve scanning the entire keyspace, and so can take a little while. See [keyspace_scan_count](#keyspace_scan_count) for tuning help.

In addition, the `X-Purge` request header will propagate to all URIs purged as a result of the wildcard, making it possible to trigger site / section wide revalidation for example. Again, be careful what you wish for.

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


### Load balancing upstreams

Multiple upstreams can be load balanced (and optionally health-checked) by passing a configured instance of [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) and setting [use_resty_upstream](#use_resty_upstream) to `true`.


### Redis Sentinel

Support for Redis [Sentinel](http://redis.io/topics/sentinel) is fully integrated, making it possible to run master / slave pairs, where Sentinel promotes the slave to master in the event of failure, without losing cache. 

Cache reads will be served from the slave in the window between the master failing and the slave being promoted, whilst writes are temporarily proxied without cache.

Instead of specifying a [redis host](#redis_host), configure your sentinels and Ledge will use this to determine the current active master.

```lua
 ledge:config_set("redis_use_sentinel", true)
 ledge:config_set("redis_sentinel_master_name", "mymaster")
 ledge:config_set("redis_sentinels", {
	 { host = "127.0.0.1", port = 6381 },
	 { host = "127.0.0.1", port = 6382 },
	 { host = "127.0.0.1", port = 6383 },
 })
```


### Collapsed forwarding

With [collapsed forwarding](#enable_collapsed_forwarding) enabled, Ledge will attempt to collapse concurrent origin requests for known (previously) cacheable resources into single upstream requests.

This is particularly useful to reduce load at the origin if a spike of traffic occurs for expired and slow content (since the chances of concurrent requests is higher).


### Edge Side Includes (ESI)

Almost complete support for the [ESI 1.0 Language Specification](https://www.w3.org/TR/esi-lang) is included, with a few exceptions, and a few enhancements.

```html
<html>
<esi:include="/header" />
<body>

   <esi:choose>
      <esi:when test="$(QUERY_STRING{foo}) == 'bar'">
         Hi
      </esi:when>
      <esi:otherwise>
         <esi:choose>
            <esi:when test="$(HTTP_COOKIE{mycookie}) == 'yep'">
               <esi:include src="http://example.com/_fragments/fragment1" />
            </esi:when>
         </esi:choose>
      </esi:otherwise>
   </esi:choose>
   
</body>
</html>
```

#### Enabling ESI

Note that simply [enabling](#esi_enabled) ESI might not be enough. We also check the [content type](#esi_content_types) against the allowed types specified, but more importantly ESI processing is contingent upon the [Edge Architecture Specification](https://www.w3.org/TR/edge-arch/). When enabled, Ledge will advertise capabilities upstream with the `Surrogate-Capability` request header, and expect the origin to include a `Surrogate-Control` header delegating ESI processing to Ledge.

If your origin is not ESI aware, a common approach is to bind to the [origin_fetched](#origin_fetched) event in order to add the `Surrogate-Control` header manually. E.g.

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

Note that if ESI is processed, downstream cache-ability is automatically dropped since you don't want other intermediaries or browsers caching the result downstream.

It's therefore best to only set `Surrogate-Control` for content which you know has ESI instructions. Whilst Ledge will detect the presence of ESI instructions when saving (and do nothing on cache HITs if no instructions are present), on a cache MISS it will have already dropped downstream cache headers before reading / saving the body. This is a side-effect of the [streaming architecture](#streaming-architecture).

#### Regular expressions in conditions

In addition to the operators defined in the [ESI specification](https://www.w3.org/TR/esi-lang), we also support regular expressions in conditions (as string literals), using the `=~` operator.

```html
<esi:choose>
   <esi:when test="$(QUERY_STRING{name}) =~ '/james|john/i'">
      Hi James or John
   </esi:when>
</esi:choose>
```

Supported modifiers are as per the [ngx.re.*](https://github.com/openresty/lua-nginx-module#ngxrematch) documentation.

#### Custom ESI variables

In addition to the variables defined in the [ESI specification](https://www.w3.org/TR/esi-lang), it is possible to stuff custom variables into a special table before running Ledge.

A common use case is to combine the [Geo IP](http://nginx.org/en/docs/http/ngx_http_geoip_module.html) module variables for use in ESI conditions.

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

ESI args are query string parameters identified by a configurable prefix, which defaults to `esi_`. With ESI enabled, query string parameters with this prefix are removed from the cache key and also from upstream requests, and instead stuffed into the `$(ESI_ARGS{foo})` variable for use in ESI, typically in conditions.

This has the effect of allowing query string parameters to alter the page layout without splitting the cache, since variables are used exclusively by the ESI processor, downstream of cache.

`$> curl -H "Host: example.com" http://cache.example.com/page1?esi_display_mode=summary`

```html
<esi:choose>
   <esi:when test="$(ESI_ARGS{display_mode}) == 'summary'">
      <!-- SUMMARY -->
   </esi:when>
   <esi:when test="$(ESI_ARGS{display_mode}) == 'details'">
      <!-- DETAILS -->
   </esi:when>
</esi:choose>
```

In this example, the `esi_display_mode` values of `summary` or `details` will return the same cache HIT, but display different content.

#### Missing ESI features

The following parts of the [ESI specification](https://www.w3.org/TR/esi-lang) are not supported, but could be in due course if a need is identified.

* `<esi:inline>` not implemented (or advertised as a capability).
* No support for the `onerror` or `alt` attributes for `<esi:include>`. Instead, we "continue" on error by default.
* `<esi:try | attempt | except>` not implemented.
* The "dictionary (special)" substructure variable type for `HTTP_USER_AGENT` is not implemented.


## Installation

Ledge is a Lua module for OpenResty. It is not designed to work in a pure Lua environment, and depends completely upon Redis data structures to function.

*Note: Currently all cache and metadata is stored in Redis, and thus in **memory**. This is an important consideration if you plan on having a very large cache. There are longer term plans to optionally move response body storage to a disk-backed system.*

Download and install:

* [OpenResty](http://openresty.org/) >= 1.9.x *(With LuaJIT enabled)*
* [Redis](http://redis.io/download) >= 2.8.x *(Note: Redis 3.2.x is not yet supported)*
* [LuaRocks](https://luarocks.org/) *(Not required, but simplifies installation)*

```
luarocks install ledge
```

This will install the latest stable release, and all other Lua module dependencies, which are:

* [lua-resty-http](https://github.com/pintsized/lua-resty-http)
* [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector)
* [lua-resty-qless](https://github.com/pintsized/lua-resty-qless)
* [lua-resty-cookie](https://github.com/cloudflare/lua-resty-cookie)
* [lua-ffi-zlib](https://github.com/hamishforbes/lua-ffi-zlib)
* [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream)

Review the [lua-nginx-module](https://github.com/openresty/lua-nginx-module) documentation on how to run Lua code in Nginx. If you are new to OpenResty, it's important to take the time to do this properly, as the environment is quite specific.

In your `nginx.conf` file:

1. Ensure that [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) is set correctly to locate Lua modules installed by LuaRocks. In most cases the default will be fine.

2. Enable the [lua_check_client_abort](https://github.com/openresty/lua-nginx-module#lua_check_client_abort) directive to avoid orphaned connections to both the origin and Redis.

3. Ensure [if_modified_since](http://nginx.org/en/docs/http/ngx_http_core_module.html#if_modified_since) is set to `Off` otherwise Nginx's own conditional validation will interfere.


### Minimal configuration

To have Ledge respond to a request, we instantiate a global instance and set any global configuration using the [init_by_lua_block](https://github.com/openresty/lua-nginx-module#init_by_lua) directive, start the Ledge background workers with the [init_worker_by_lua_block](https://github.com/openresty/lua-nginx-module#init_worker_by_lua) directive, and configure anything route specific in the [content_by_lua_block](https://github.com/openresty/lua-nginx-module#content_by_lua) directives, before calling `ledge:run()`.

Assuming you have Redis running on the the default `localhost:6379`.

```nginx
nginx {
	if_modified_since Off;
	lua_check_client_abort On;
	
	init_by_lua_block {
		ledge = require("ledge.ledge").new()
	}
	
	init_worker_by_lua_block {
		ledge:run_workers()
	}

	server {
		server_name example.com;
		listen 80;
		
		location / {
			content_by_lua_block {
				ledge:config_set("upstream_host", "upstream.example.com")
				ledge:run()
			}
		}
	}
}
```


## Configuration options

Options can be specified globally with the `init_by_lua_block` directive, or for a specific server / location with `content_by_lua_block` directives.

Config set in `content_by_lua_block` will only affect that specific location, and runs in the context of the current running request. That is, you can write request-specific conditions which dynamically set configuration for matching requests.

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


### origin_mode

syntax: `ledge:config_set("origin_mode", ledge.ORIGIN_MODE_NORMAL | ledge.ORIGIN_MODE_BYPASS | ledge.ORIGIN_MODE_AVOID)`

default: `ledge.ORIGIN_MODE_NORMAL`

Determines the overall behaviour for connecting to the origin.  `ORIGIN_MODE_NORMAL` will assume the origin is up, and connect as necessary.

`ORIGIN_MODE_AVOID` is similar to Squid's `offline_mode`, where any retained cache (expired or not) will be served rather than trying the origin, regardless of cache-control headers, but the origin will be tried if there is no cache to serve.

`ORIGIN_MODE_BYPASS` is the same as `AVOID`, except if there is no cache to serve we send a `503 Service Unavailable` status code to the client and never attempt an upstream connection.


### upstream_connect_timeout

syntax: `ledge:config_set("upstream_connect_timeout", 1000)`

default: `500 (ms)`

Maximum time to wait for an upstream connection (in milliseconds). If it is exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.


### upstream_read_timeout

syntax: `ledge:config_set("upstream_read_timeout", 5000)`

default: `5000 (ms)`

Maximum time to wait for data on a connected upstream socket (in milliseconds).  If it is exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.


### upstream_host

syntax: `ledge:config_set("upstream_host", "web01.example.com")`

default: `empty (must be set)`

Specifies the hostname or IP address of the upstream host. If a hostname is specified, you must configure the Nginx [resolver](http://nginx.org/en/docs/http/ngx_http_core_module.html#resolver) somewhere, for example:

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

Toggles the use of SSL on the upstream connection. Other `upstream_ssl_*` options will be ignored if this is not set to `true`.


### upstream_ssl_server_name

syntax: `ledge:config_set("upstream_ssl_server_name", "www.example.com")`

default: `nil`

Specifies the SSL server name used for Server Name Indication (SNI). See [sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more information.


### upstream_ssl_verify

syntax: `ledge:config_set("upstream_ssl_verify", true)`

default: `false`

Toggles SSL verification. See [sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more information.


### use_resty_upstream

syntax: `ledge:config_set("use_resty_upstream", true)`

default: `false`

Toggles whether to use a preconfigured [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) instance (see below), instead of the above `upstream_*` options.


### resty_upstream

syntax: `ledge:config_set("resty_upstream", my_upstream)`

default: `nil`

Specifies a preconfigured [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) instance to be used for all upstream connections. This provides upstream load balancing and active healthchecks.


### buffer_size

syntax: `ledge:config_set("buffer_size", 2^17)`

default: `2^16 (64KB in bytes)`

Specifies the internal buffer size (in bytes) used for data to be read/written/served. Upstream responses are read in chunks of this maximum size, preventing allocation of large amounts of memory in the event of receiving large files. Data is also stored internally as a list of chunks, and delivered to the Nginx output chain buffers in the same fashion.

The only exception is if ESI is configured, and Ledge has determined there are ESI instructions to process, and any of these instructions span a given chunk.  In this case, buffers are concatenated until a complete instruction is found, and then ESI operates on this new buffer.


### cache_max_memory

syntax: `ledge:config_set("cache_max_memory", 4096)`

default: `2048 (KB)`

Specifies (in kilobytes) the maximum size a cache item can occupy before we give up attempting to store (and delete the entity).

Note that since entities are written and served as a list of buffers, when replacing an entity we create a new entity list and only delete the old one after existing read operations should have completed, marking the old entity for garbage collection.

As a result, it is possible for multiple entities for a given cache key to exist, each up to a maximum of `cache_max_memory`. However this should only every happen quite temporarily, the timing of which is configurable with [minimum_old_entity_download_rate](#minimum_old_entity_download_rate).


### advertise_ledge

syntax: `ledge:config_set("advertise_ledge", false)`

default `true`

If set to false, disables advertising the software name and version, e.g. `(ledge/1.26)` from the `Via` response header.


### redis_database

syntax: `ledge:config_set("redis_database", 1)`

default: `0`

Specifies the Redis database to use for cache data / metadata.


### redis_qless_database

syntax: `ledge:config_set("redis_qless_database", 2)`

default: `1`

Specifies the Redis database to use for [lua-resty-qless](https://github.com/pintsized/lua-resty-qless) jobs. These are background tasks such as garbage collection and revalidation, which are managed by Qless. It can be useful to keep these in a separate database, purely for namespace sanity.


### redis_connect_timeout

syntax: `ledge:config_set("redis_connect_timeout", 1000)`

default: `500 (ms)`

Maximum time to wait for a Redis connection (in milliseconds). If it is exceeded, we send a `503` status code.


### redis_read_timeout

syntax: `ledge:config_set("redis_read_timeout", 5000)`

default: `5000 (ms)`

Maximum time to wait for data on a connected Redis socket (in milliseconds). If it is exceeded, we send a `503 Service Unavailable` status.


### redis_keepalive_timeout

syntax: `ledge:config_set("redis_keepalive_timeout", 120)`

default: `60s or lua_socket_keepalive_timeout (sec)`


### redis_keepalive_poolsize

syntax: `ledge:config_set("redis_keepalive_poolsize", 60)`

default: `Defaults to 30 or lua_socket_pool_size`


### redis_host

`syntax: ledge:config_set("redis_host", { host = "127.0.0.1", port = 6380 })`

`default: { host = "127.0.0.1", port = 6379, password = nil, socket = nil }`

Specifies the Redis host to connect to. If `socket` is specified then `host` and `port` are ignored. See the [lua-resty-redis](https://github.com/openresty/lua-resty-redis#connect) documentation for more details.


### redis_use_sentinel

syntax: `ledge:config_set("redis_use_sentinel", true)`

default: `false`

Toggles the use of [Redis Sentinel](http://redis.io/topics/sentinel) for Redis host discovery. If set to `true`, then [redis_sentinels](#redis_sentinels) will override [redis_host](#redis_host).


### redis_sentinel_master_name

syntax: `ledge:config_set("redis_sentinel_master_name", "master")`

default: `mymaster`

Specifies the [Redis Sentinel](http://redis.io/topics/sentinel) master name.


### redis_sentinels

`syntax: ledge:set_config("redis_sentinels", { { host = "127.0.0.1", port = 6381 }, { host = "127.0.0.1", port = 6382 }, { host = "127.0.0.1", port = 6383 }, }`

default: `nil`

Specifies a list of [Redis Sentinels](http://redis.io/topics/sentinel) to be tried in order. Once connected, Sentinel provides us with a master Redis node to connect to. If it cannot identify a master, or if the master node cannot be connected to, we ask Sentinel for a list of slaves to try.

This normally happens when the master has gone down, but Sentinel has not yet promoted a slave. During this window, we optimistically try to connect to a slave for read-only operations, since cache-hits may still be served.


### keep_cache_for

syntax: `ledge:config_set("keep_cache_for", 86400 * 14)`

default: `86400 * 30 (1 month in seconds)`

Specifies how long to retain cache data past its expiry date. This allows us to serve stale cache in the event of upstream failure with [stale_if_error](#stale_if_error) or [origin_mode](#origin_mode) settings.

Items will be evicted when under memory pressure provided you are using one of the Redis [volatile eviction policies](http://redis.io/topics/lru-cache), so there should generally be no real need to lower this for space reasons.

Items at the extreme end of this (i.e. nearly a month old) are clearly very rarely requested, or more likely, have been removed at the origin.


### minimum_old_entity_download_rate

syntax: `ledge:config_set("minimum_old_entity_download_rate", 128)`

default: `56 (kbps)`

Clients reading slower than this who are also unfortunate enough to have started reading from an entity which has been replaced (due to another client causing a revalidation for example), may have their entity garbage collected before they finish, resulting in an incomplete resource being delivered.

Lowering this is fairer on slow clients, but widens the potential window for multiple old entities to stack up, which in turn could threaten Redis storage space and force evictions.

This design favours high availability (since there are no read-locks, we can serve cache from Redis slaves in the event of failure) on the assumption that the chances of this causing incomplete resources to be served are quite low.


### cache_key_spec

`syntax: ledge:config_set("cache_key_spec", { ngx.var.host, ngx.var.uri, ngx.var.args })`

`default: { ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }`

Specifies the cache key format. This allows you to abstract certain items for great hit rates (at the expense of collisions), for example.

The default spec is:

```lua
{ ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }
```

Which will generate cache keys in Redis such as:

```
ledge:cache:http:example.com:/about
ledge:cache:http:example.com:/about:p=2&q=foo
```

If you're doing SSL termination at Nginx and your origin pages look the same for HTTPS and HTTP traffic, you could provide a cache key spec omitting `ngx.var.scheme`, to avoid splitting the cache when the content is identical.


### enable_collapsed_forwarding

syntax: `ledge:config_get("enable_collapsed_forwarding", true)`

default: `false`

With collapsed forwarding enabled, Ledge will attempt to collapse concurrent origin requests for known (previously) cacheable resources into single upstream requests.

This is useful in reducing load at the origin if requests are expensive. The longer the origin request, the more useful this is, since the greater the chance of concurrent requests.

Ledge wont collapse requests for resources that it hasn't seen before and weren't cacheable last time. If the resource has become non-cacheable since the last request, the waiting requests will go to the origin themselves (having waited on the first request to find this out).


### collapsed_forwarding_window

syntax: `ledge:config_set("collapsed_forwarding_window", 30000)`

default: `60000 (ms)`

When collapsed forwarding is enabled, if a fatal error occurs during the origin request, the collapsed requests may never receive the response they are waiting for. This setting puts a limit on how long they will wait, and how long before new requests will decide to try the origin for themselves.

If this is set shorter than your origin takes to respond, then you may get more upstream requests than desired. Fatal errors (server reboot etc) may result in hanging connections for up to the maximum time set. Normal errors (such as upstream timeouts) work independently of this setting.


### esi_enabled

syntax: `ledge:config_set("esi_enabled", true)`

default: `false`

Toggles [ESI](http://www.w3.org/TR/esi-lang) scanning and processing, though behaviour is also contingent upon [esi_content_types](#esi_content_types) and [esi_surrogate_delegation](#esi_surrogate_delegation) settings, as well as `Surrogate-Control` / `Surrogate-Capability` headers.

ESI instructions are detected on the slow path (i.e. when fetching from the origin), so only instructions which are known to be present are processed on cache HITs.


### esi_content_types

syntax: `ledge:config_set("esi_content_types", { "text/html", "text/javascript" })`

default: `{ text/html }`

Specifies content types to perform ESI processing on. All other content types will not be considered for processing.


### esi_allow_surrogate_delegation

syntax: `ledge:config_set("esi_allow_surrogate_delegation", true)`

default: false

[ESI Surrogate Delegation](http://www.w3.org/TR/edge-arch) allows for downstream intermediaries to advertise a capability to process ESI instructions nearer to the client. By setting this to `true` any downstream offering this will disable ESI processing in Ledge, delegating it downstream.

When set to a Lua table of IP address strings, delegation will only be allowed to this specific hosts. This may be important if ESI instructions contain sensitive data which must be removed.


### esi_recursion_limit

syntax: `ledge:config_set("esi_recursion_limit", 5)`

default: 10

Limits fragment inclusion nesting, to avoid accidental infinite recursion.


### esi_pre_include_callback

syntax: `ledge:config_set("esi_pre_include_callback", function(req_params) ... end)`

default: nil

A function provided here will be called each time the ESI parser goes to make an outbound HTTP request for a fragment. The request parameters are passed through and can be manipulated here, for example to modify request headers.


### esi_args_prefix

syntax: `ledge:config_set("esi_args_prefix", "__esi_")`

default: "esi_"

URI args prefix for parameters to be ignored from the cache key (and not proxied upstream), for use exclusively with ESI rendering logic. Set to nil to disable the feature.


### gunzip_enabled

syntax: `ledge:config_set("gunzip_enabled", false)`

default: true

With this enabled, gzipped responses will be uncompressed on the fly for clients that do not set `Accept-Encoding: gzip`. Note that if we receive a gzipped response for a resource containing ESI instructions, we gunzip whilst saving and store uncompressed, since we need to read the ESI instructions.

Also note that `Range` requests for gzipped content must be ignored - the full response will be returned.


### keyspace_scan_count

syntax: `ledge:config_set("keyspace_scan_count", 10000)`

default: 1000

Tunes the behaviour of keyspace scans, which occur when sending a PURGE request with wildcard syntax.

A higher number may be better if latency to Redis is high and the keyspace is large.



## Events

Events are broadcast at various stages, which can be listened for using Lua functions.

For example, this may be useful if an upstream doesn't set optimal `Cache-Control` headers, and cannot be easily be modified itself.

*Note: Events which pass through a `res` (response) object never contain the response body itself, since this is streamed at the point of serving.*

Example:

```lua
ledge:bind("origin_fetched", function(res)
    res.header["Cache-Control"] = "max-age=86400"
    res.header["Last-Modified"] = ngx.http_time(ngx.time())
end)
```

*Note: that the creation of closures in Lua can be kinda expensive, so you may wish to put these functions in a module and pass them through.*

## Event types

* [cache_accessed](#cache_accessed)
* [origin_required](#origin_required)
* [before_request](#before_request)
* [origin_fetched](#origin_fetched)
* [before_save](#before_save)
* [response_ready](#response_ready)
* [before_save_revalidation_data](#before_save_revalidation_data)

### cache_accessed

syntax: `ledge:bind("cache_accessed", function(res) -- end)`

params: `res` The cached `ledge.response` instance.

Fires directly after the response was successfully loaded from cache.


### origin_required

syntax: `ledge:bind("origin_required", function() -- end)`

params: `nil`

Fires when decided we need to request from the origin.


### before_request

syntax: `ledge:bind("before_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to send to the [httpc:request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform an origin request.


### origin_fetched

syntax: `ledge:bind("origin_fetched", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when the status/headers have been fetched, but before it is stored. Typically used to override cache headers before we decide what to do with this response.

*Note: unlike `before_save` below, this fires for all fetched content, not just cacheable content.*


### before_save

syntax: `ledge:bind("before_save", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to save the response.


### response_ready

syntax: `ledge:bind("response_ready", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to serve. Often used to modify downstream headers.


### before_save_revalidation_data

syntax: `ledge:bind("before_save_revalidation_data", function(reval_params, reval_headers) -- end)`

params: `reval_params`. Table of revalidation params.

params: `reval_headers`. Table of revalidation headers.

Fires when a background revalidation is triggered or when cache is being saved. Allows for modifying the headers and paramters (such as connection parameters) which are inherited by the background revalidation.

The `reval_params` are values derived from the current running configuration for:

* server_addr
* server_port
* scheme
* uri
* connect_timeout
* read_timeout
* ssl_server_name
* ssl_verify


## Background workers

Ledge uses [lua-resty-qless](https://github.com/pintsized/lua-resty-qless) to schedule and process background tasks, which are stored in Redis (usually in a separate DB to cache data).

Jobs are scheduled for background revalidation requests as well as wildcard PURGE requests, but most importantly for garbage collection of replaced body entities.

That is, it's very important that jobs are being run properly and in a timely fashion.

Installing the [web user interface](https://github.com/hamishforbes/lua-resty-qless-web) can be very helpful to check this.

You may also wish to tweak the [qless job history](https://github.com/pintsized/lua-resty-qless#configuration-options) settings if it takes up too much space.

### run_workers

syntax: `init_worker_by_lua_block { ledge:run_workers(options) }`

default options: `{ interval = 10, concurrency = 1, purge_concurrency = 1, revalidate_concurrency = 1 }`

Starts the Ledge workers within each Nginx worker process. When no jobs are left to be processed, each worker will wait for `interval` before checking again.

You can have many worker "light threads" per worker process, by upping the concurrency. They will yield to each other when doing i/o. Concurrency can be adjusted for each job type indepedently:

* __concurrency__: Controls core job concurrency, which currently is just the garbage collection jobs.
* __purge_concurrency__: Controls job concurrency for backgrounded purge requests.
* __revalidate_concurrency__: Controls job concurrency for backgrounded revalidation.

The default options are quite conservative. You probably want to up the `*concurrency` options and lower the `interval` on busy systems.


## Logging

For cacheable responses, Ledge will add headers indicating the cache status. These can be added to your Nginx log file in the normal way.

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

This header follows the convention set by other HTTP cache servers. It indicates simply `HIT` or `MISS` and the host name in question, preserving upstream values when more than one cache server is in play. 

If a resource is considered not cacheable, the `X-Cache` header will not be present in the response.

For example:

* `X-Cache: HIT from ledge.tld` *A cache hit, with no (known) cache layer upstream.*
* `X-Cache: HIT from ledge.tld, HIT from proxy.upstream.tld` *A cache hit, also hit upstream.*
* `X-Cache: MISS from ledge.tld, HIT from proxy.upstream.tld` *A cache miss, but hit upstream.*
* `X-Cache: MISS from ledge.tld, MISS from proxy.upstream.tld` *Regenerated at the origin.*



## Author

James Hurst <james@pintsized.co.uk>


## Licence

This module is licensed under the 2-clause BSD license.

Copyright (c) James Hurst <james@pintsized.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
