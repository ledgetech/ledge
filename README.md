# Ledge

An [ESI](https://www.w3.org/TR/esi-lang) capable HTTP cache for [Nginx](http://nginx.org) / [OpenResty](https://openresty.org), backed by [Redis](http://redis.io).


## Table of Contents

* [Overview](#overview)
* [Installation](#installation)
* [Nomenclature](#nomenclature)
* [Minimal configuration](#minimal-configuration)
* [Configuration options](#configuration-options)
* [Binding to events](#events)
* [Background workers](#background-workers)
* [Logging](#logging)
* [Licence](#licence)


## Overview

Ledge aims to be an RFC compliant HTTP reverse proxy cache, providing a fast, robust and scalable alternative to Squid / Varnish etc.

Moreover, it is particularly suited to applications where the origin is expensive or distant, making it desirable to serve from cache as optimistically as possible. For example, using [ESI](#edge-side-includes-esi) to separate page
fragments where their TTL differs, serving stale content whilst [revalidating in the background](#stale--background-revalidation), [collapsing](#collapsed-forwarding) concurrent similar upstream requests, dynamically modifying the cache key specification, and [automatically revalidating](#revalidate-on-purge) content with a PURGE API.


## Installation

### 1. Download and install:

* [OpenResty](http://openresty.org/) >= 1.11.x
* [Redis](http://redis.io/download) >= 2.8.x
* [LuaRocks](https://luarocks.org/)

### 2. Install Ledge and its dependencies:

```
luarocks install ledge
```

This will install the latest stable release, and all other Lua module dependencies, which if installing manually without LuaRocks are:

* [lua-resty-http](https://github.com/pintsized/lua-resty-http)
* [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector)
* [lua-resty-qless](https://github.com/pintsized/lua-resty-qless)
* [lua-resty-cookie](https://github.com/cloudflare/lua-resty-cookie)
* [lua-ffi-zlib](https://github.com/hamishforbes/lua-ffi-zlib)
* [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) *(optional, for load balancing / healthchecking upstreams)*

### 3. Review OpenResty documentation

If you are new to OpenResty, it's quite important to review the [lua-nginx-module](https://github.com/openresty/lua-nginx-module) documentation on how to run Lua code in Nginx, as the environment is unusual. Specifcally, it's useful to understand the meaning of the different Nginx phase hooks such as `init_by_lua` and `content_by_lua`, as well as how the `lua-nginx-module` locates Lua modules with the [lua_package_path](https://github.com/openresty/lua-nginx-module#lua_package_path) directive.


## Nomenclature

The central module is called `ledge`, and provides factory methods for creating `handler` instances (for handling a request) and `worker` instances (for running background tasks). The `ledge` module is also where global configuration is managed.

A `handler` is short lived. It is typically created at the beginning of the Nginx `content` phase for a request, and when its `run()` method is called, takes responsibility for processing the current request and delivering a response. When `run()` has completed, HTTP status, headers and body will have been delivered to the client.

A `worker` is long lived, and there is one per Nginx worker process. It is created when Nginx starts a worker process, and dies when the Nginx worker dies. The `worker` pops queued background jobs and processes them.

An `upstream` is the only thing which must be manually configured, and points to another HTTP host where actual content lives. Typically one would use DNS to resolve client connections to the Nginx server running Ledge, and tell Ledge where to fetch from with the `upstream` configuration. As such, Ledge isn't designed to work as a forwarding proxy.

[Redis](http://redis.io) is used for much more than cache storage. We rely heavily on its data structures to maintain cache `metadata`, as well as embedded Lua scripts for atomic task management and so on. By default, all cache body data and `metadata` will be stored in the same Redis instance. The location of cache `metadata` is global, set when Nginx starts up.

Cache body data is handled by the `storage` system, and as mentioned, by default shares the same Redis instance as the `metadata`. However, `storage` is abstracted via a driver system making it possible to store cache body data in a separate Redis instance, or a group of horizontally scalable Redis instances via a [proxy](https://github.com/twitter/twemproxy), or to roll your own `storage` driver, for example targeting PostreSQL or even simply a filesystem. It's perhaps important to consider that by default all cache storage uses Redis, and as such is bound by system memory.


## Minimal configuration

Assuming you have Redis running on `localhost:6379`, and your upstream is at `localhost:8080`.

```nginx
http {
    if_modified_since Off;
    lua_check_client_abort On;

    init_worker_by_lua_block {
        require("ledge").create_worker():run()
    }

    server {
        server_name example.com;
        listen 80;

        location / {
            content_by_lua_block {
                require("ledge").create_handler({
                    upstream_host = "127.0.0.1",
                    upstream_port = 8080,
                }):run()
            }
        }
    }
}
```


## Config systems

There are four different layers to the `configuration` system. Firstly there is `metadata` and default `handler` config, which are global and must be set during the Nginx `init` phase. `metadata` config is simply the Redis connection details, but the default `handler` config can be any `handler` configuration which you want to be pre-set for all spawned request `handler` instances. Beyond this, you can specify `handler` config on an Nginx `location` block basis, which will override any defaults given. And finally, there are some performance tuning config options for the `worker` instances.


### Metadata config

This is specified during the Nginx `init` phase, passing a configuration table to the `ledge.configure()` method.

```nginx
init_by_lua_block {
    require("ledge").configure({
        redis_connector_params = {
            url = "redis://mypassword@127.0.0.1:6380/3",
        }
        qless_db = 4,
    })
}
```

#### redis_connector_params

`default: {}`

Ledge uses [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector) to handle all Redis connections. It simply passes anything given in `redis_connector_params` straight to `lua-resty-redis-connector`.

#### qless_db

`default: 1`

Specifies the Redis DB number to store [qless](https://github.com/pintsized/lua-resty-qless) background job data.


### Handler config

Options can be specified globally by calling `ledge:set_handler_defaults()`
inside the `init_by_lua_block` directive, or when creating a handler in a
`content_by_lua_block` directive for server / location specific configuration.

 * [origin_mode](#origin_mode)
 * [upstream_connect_timeout](#upstream_connect_timeout)
 * [upstream_read_timeout](#upstream_read_timeout)
 * [upstream_host](#upstream_host)
 * [upstream_port](#upstream_port)
 * [upstream_use_ssl](#upstream_use_ssl)
 * [upstream_ssl_server_name](#upstream_ssl_server_name)
 * [upstream_ssl_verify](#upstream_ssl_verify)
 * [buffer_size](#buffer_size)
 * [cache_max_memory](#cache_max_memory)
 * [advertise_ledge](#advertise_ledge)
 * [keep_cache_for](#keep_cache_for)
 * [minimum_old_entity_download_rate](#minimum_old_entity_download_rate)
 * [cache_key_spec](#cache_key_spec)
 * [enable_collapsed_forwarding](#enable_collapsed_forwarding)
 * [collapsed_forwarding_window](#collapsed_forwarding_window)
 * [esi_enabled](#esi_enabled)
 * [esi_content_types](#esi_content_types)
 * [esi_allow_surrogate_delegation](#esi_allow_surrogate_delegation)
 * [esi_recursion_limit](#esi_recursion_limit)
 * [esi_args_prefix](#esi_args_prefix)
 * [gunzip_enabled](#gunzip_enabled)
 * [keyspace_scan_count](#keyspace_scan_count)


### origin_mode

syntax: `ledge:config_set("origin_mode", ledge.ORIGIN_MODE_NORMAL | ledge.ORIGIN_MODE_BYPASS | ledge.ORIGIN_MODE_AVOID)`

default: `ledge.ORIGIN_MODE_NORMAL`

Determines the overall behaviour for connecting to the origin.
`ORIGIN_MODE_NORMAL` will assume the origin is up, and connect as necessary.

`ORIGIN_MODE_AVOID` is similar to Squid's `offline_mode`, where any retained
cache (expired or not) will be served rather than trying the origin, regardless
of cache-control headers, but the origin will be tried if there is no cache to
serve.

`ORIGIN_MODE_BYPASS` is the same as `AVOID`, except if there is no cache to
serve we send a `503 Service Unavailable` status code to the client and never
attempt an upstream connection.


### upstream_connect_timeout

syntax: `ledge:config_set("upstream_connect_timeout", 1000)`

default: `500 (ms)`

Maximum time to wait for an upstream connection (in milliseconds). If it is
exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error)
is configured.


### upstream_read_timeout

syntax: `ledge:config_set("upstream_read_timeout", 5000)`

default: `5000 (ms)`

Maximum time to wait for data on a connected upstream socket (in milliseconds).
If it is exceeded, we send a `503` status code, unless
[stale_if_error](#stale_if_error) is configured.


### upstream_host

syntax: `ledge:config_set("upstream_host", "web01.example.com")`

default: `empty (must be set)`

Specifies the hostname or IP address of the upstream host. If a hostname is
specified, you must configure the Nginx
[resolver](http://nginx.org/en/docs/http/ngx_http_core_module.html#resolver)
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

Toggles the use of SSL on the upstream connection. Other `upstream_ssl_*`
options will be ignored if this is not set to `true`.


### upstream_ssl_server_name

syntax: `ledge:config_set("upstream_ssl_server_name", "www.example.com")`

default: `nil`

Specifies the SSL server name used for Server Name Indication (SNI). See
[sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake)
for more information.


### upstream_ssl_verify

syntax: `ledge:config_set("upstream_ssl_verify", true)`

default: `false`

Toggles SSL verification. See
[sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake)
for more information.


### use_resty_upstream

syntax: `ledge:config_set("use_resty_upstream", true)`

default: `false`

Toggles whether to use a preconfigured
[lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream)
instance (see below), instead of the above `upstream_*` options.


### resty_upstream

syntax: `ledge:config_set("resty_upstream", my_upstream)`

default: `nil`

Specifies a preconfigured
[lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream)
instance to be used for all upstream connections. This provides upstream load
balancing and active healthchecks.


### buffer_size

syntax: `ledge:config_set("buffer_size", 2^17)`

default: `2^16 (64KB in bytes)`

Specifies the internal buffer size (in bytes) used for data to be
read/written/served. Upstream responses are read in chunks of this maximum size,
preventing allocation of large amounts of memory in the event of receiving large
files. Data is also stored internally as a list of chunks, and delivered to the
Nginx output chain buffers in the same fashion.

The only exception is if ESI is configured, and Ledge has determined there are
ESI instructions to process, and any of these instructions span a given chunk.
In this case, buffers are concatenated until a complete instruction is found,
and then ESI operates on this new buffer.


### cache_max_memory

syntax: `ledge:config_set("cache_max_memory", 4096)`

default: `2048 (KB)`

Specifies (in kilobytes) the maximum size a cache item can occupy before we give
up attempting to store (and delete the entity).

Note that since entities are written and served as a list of buffers, when
replacing an entity we create a new entity list and only delete the old one
after existing read operations should have completed, marking the old entity for
garbage collection.

As a result, it is possible for multiple entities for a given cache key to
exist, each up to a maximum of `cache_max_memory`. However this should only
every happen quite temporarily, the timing of which is configurable with
[minimum_old_entity_download_rate](#minimum_old_entity_download_rate).


### advertise_ledge

syntax: `ledge:config_set("advertise_ledge", false)`

default `true`

If set to false, disables advertising the software name and version,
e.g. `(ledge/1.26)` from the `Via` response header.


### keep_cache_for

syntax: `ledge:config_set("keep_cache_for", 86400 * 14)`

default: `86400 * 30 (1 month in seconds)`

Specifies how long to retain cache data past its expiry date. This allows us to
serve stale cache in the event of upstream failure with
[stale_if_error](#stale_if_error) or [origin_mode](#origin_mode) settings.

Items will be evicted when under memory pressure provided you are using one of
the Redis [volatile eviction policies](http://redis.io/topics/lru-cache), so
there should generally be no real need to lower this for space reasons.

Items at the extreme end of this (i.e. nearly a month old) are clearly very
rarely requested, or more likely, have been removed at the origin.


### minimum_old_entity_download_rate

syntax: `ledge:config_set("minimum_old_entity_download_rate", 128)`

default: `56 (kbps)`

Clients reading slower than this who are also unfortunate enough to have started
reading from an entity which has been replaced (due to another client causing a
revalidation for example), may have their entity garbage collected before they
finish, resulting in an incomplete resource being delivered.

Lowering this is fairer on slow clients, but widens the potential window for
multiple old entities to stack up, which in turn could threaten Redis storage
space and force evictions.

This design favours high availability (since there are no read-locks, we can
serve cache from Redis slaves in the event of failure) on the assumption that
the chances of this causing incomplete resources to be served are quite low.


### cache_key_spec

`syntax: ledge:config_set("cache_key_spec", { ngx.var.host, ngx.var.uri, ngx.var.args })`

`default: { ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }`

Specifies the cache key format. This allows you to abstract certain items for
great hit rates (at the expense of collisions), for example.

The default spec is:

```lua
{ ngx.var.scheme, ngx.var.host, ngx.var.uri, ngx.var.args }
```

Which will generate cache keys in Redis such as:

```
ledge:cache:http:example.com:/about
ledge:cache:http:example.com:/about:p=2&q=foo
```

If you're doing SSL termination at Nginx and your origin pages look the same for
HTTPS and HTTP traffic, you could provide a cache key spec omitting
`ngx.var.scheme`, to avoid splitting the cache when the content is identical.


### enable_collapsed_forwarding

syntax: `ledge:config_get("enable_collapsed_forwarding", true)`

default: `false`

With collapsed forwarding enabled, Ledge will attempt to collapse concurrent
origin requests for known (previously) cacheable resources into single upstream
requests.

This is useful in reducing load at the origin if requests are expensive. The
longer the origin request, the more useful this is, since the greater the chance
of concurrent requests.

Ledge wont collapse requests for resources that it hasn't seen before and
weren't cacheable last time. If the resource has become non-cacheable since the
last request, the waiting requests will go to the origin themselves (having
waited on the first request to find this out).


### collapsed_forwarding_window

syntax: `ledge:config_set("collapsed_forwarding_window", 30000)`

default: `60000 (ms)`

When collapsed forwarding is enabled, if a fatal error occurs during the origin
request, the collapsed requests may never receive the response they are waiting
for. This setting puts a limit on how long they will wait, and how long before
new requests will decide to try the origin for themselves.

If this is set shorter than your origin takes to respond, then you may get more
upstream requests than desired. Fatal errors (server reboot etc) may result in
hanging connections for up to the maximum time set. Normal errors (such as
upstream timeouts) work independently of this setting.


### esi_enabled

syntax: `ledge:config_set("esi_enabled", true)`

default: `false`

Toggles [ESI](http://www.w3.org/TR/esi-lang) scanning and processing, though
behaviour is also contingent upon [esi_content_types](#esi_content_types) and
[esi_surrogate_delegation](#esi_surrogate_delegation) settings, as well as
`Surrogate-Control` / `Surrogate-Capability` headers.

ESI instructions are detected on the slow path (i.e. when fetching from the
origin), so only instructions which are known to be present are processed on
cache HITs.


### esi_content_types

syntax: `ledge:config_set("esi_content_types", { "text/html", "text/javascript" })`

default: `{ text/html }`

Specifies content types to perform ESI processing on. All other content types
will not be considered for processing.


### esi_allow_surrogate_delegation

syntax: `ledge:config_set("esi_allow_surrogate_delegation", true)`

default: false

[ESI Surrogate Delegation](http://www.w3.org/TR/edge-arch) allows for downstream
intermediaries to advertise a capability to process ESI instructions nearer to
the client. By setting this to `true` any downstream offering this will disable
ESI processing in Ledge, delegating it downstream.

When set to a Lua table of IP address strings, delegation will only be allowed
to this specific hosts. This may be important if ESI instructions contain
sensitive data which must be removed.


### esi_recursion_limit

syntax: `ledge:config_set("esi_recursion_limit", 5)`

default: 10

Limits fragment inclusion nesting, to avoid accidental infinite recursion.


### esi_args_prefix

syntax: `ledge:config_set("esi_args_prefix", "__esi_")`

default: "esi\_"

URI args prefix for parameters to be ignored from the cache key
(and not proxied upstream), for use exclusively with ESI rendering logic.
Set to nil to disable the feature.


### gunzip_enabled

syntax: `ledge:config_set("gunzip_enabled", false)`

default: true

With this enabled, gzipped responses will be uncompressed on the fly for clients
that do not set `Accept-Encoding: gzip`. Note that if we receive a gzipped
response for a resource containing ESI instructions, we gunzip whilst saving and
store uncompressed, since we need to read the ESI instructions.

Also note that `Range` requests for gzipped content must be ignored - the full
response will be returned.


### keyspace_scan_count

syntax: `ledge:config_set("keyspace_scan_count", 10000)`

default: 1000

Tunes the behaviour of keyspace scans, which occur when sending a PURGE request
with wildcard syntax.

A higher number may be better if latency to Redis is high and the keyspace is
large.



## Events

Events are broadcast at various stages, which can be listened for using Lua
functions.

For example, this may be useful if an upstream doesn't set optimal
`Cache-Control` headers, and cannot be easily be modified itself.

*Note: Events which pass through a `res` (response) object never contain the
response body itself, since this is streamed at the point of serving.*

Example:

```lua
handler:bind("after_upstream_request", function(res)
    res.header["Cache-Control"] = "max-age=86400"
    res.header["Last-Modified"] = ngx.http_time(ngx.time())
end)
```

*Note: that the creation of closures in Lua can be kinda expensive, so you may wish to put these functions in a module and pass them through.*

## Event types

* [after_cache_read](#after_cache_read)
* [before_upstream_connect](#before_upstream_connect)
* [before_upstream_request](#before_upstream_request)
* [before_esi_inclulde_request"](#before_esi_include_request)
* [after_upstream_request](#after_upstream_request)
* [before_save](#before_save)
* [before_serve](#before_serve)
* [before_save_revalidation_data](#before_save_revalidation_data)

### after_cache_read

syntax: `handler:bind("after_cache_read", function(res) -- end)`

params: `res` The cached `ledge.response` instance.

Fires directly after the response was successfully loaded from cache.


### before_upstream_connect

syntax: `ledge:bind("before_upstream_connect", function(handler) -- end)`

params: `handler`. The current handler instance.

Fires before the default `handler.upstream_client` is created.  
Use to override the default `resty.http` client and provide a pre-connected client module compatible with `resty.httpc`


### before_upstream_request

syntax: `ledge:bind("before_upstream_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to send to the
[httpc:request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform an upstream request.


### before_esi_include_request

syntax: `ledge:bind("before_esi_include_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to be used for an ESI
include.

Fires when about to perform a HTTP request on behalf of an ESI include
instruction.


### after_upstream_request

syntax: `ledge:bind("after_upstream_request", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when the status/headers have been fetched, but before it is stored.
Typically used to override cache headers before we decide what to do with this
response.

*Note: unlike `before_save` below, this fires for all fetched content, not just
cacheable content.*


### before_save

syntax: `ledge:bind("before_save", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to save the response.


### before_serve

syntax: `ledge:bind("before_serve", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to serve. Often used to modify downstream headers.


### before_save_revalidation_data

syntax: `ledge:bind("before_save_revalidation_data", function(reval_params, reval_headers) -- end)`

params: `reval_params`. Table of revalidation params.

params: `reval_headers`. Table of revalidation headers.

Fires when a background revalidation is triggered or when cache is being saved.
Allows for modifying the headers and paramters (such as connection parameters)
which are inherited by the background revalidation.

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

Ledge uses [lua-resty-qless](https://github.com/pintsized/lua-resty-qless) to
schedule and process background tasks, which are stored in Redis (usually in a
separate DB to cache data).

Jobs are scheduled for background revalidation requests as well as wildcard
PURGE requests, but most importantly for garbage collection of replaced body
entities.

That is, it's very important that jobs are being run properly and in a timely
fashion.

Installing the
[web user interface](https://github.com/hamishforbes/lua-resty-qless-web) can be
very helpful to check this.

You may also wish to tweak the
[qless job history](https://github.com/pintsized/lua-resty-qless#configuration-options)
settings if it takes up too much space.

### run_workers

syntax: `init_worker_by_lua_block { ledge:create_worker(options):run() }`

default options: `{ interval = 10, concurrency = 1, purge_concurrency = 1, revalidate_concurrency = 1 }`

Starts the Ledge workers within each Nginx worker process. When no jobs are left
to be processed, each worker will wait for `interval` before checking again.

You can have many worker "light threads" per worker process, by upping the
concurrency. They will yield to each other when doing i/o. Concurrency can be
adjusted for each job type indepedently:

* __concurrency__: Controls core job concurrency, which currently is just the garbage collection jobs.
* __purge_concurrency__: Controls job concurrency for backgrounded purge requests.
* __revalidate_concurrency__: Controls job concurrency for backgrounded revalidation.

The default options are quite conservative. You probably want to up the
`*concurrency` options and lower the `interval` on busy systems.


## Logging

For cacheable responses, Ledge will add headers indicating the cache status.
These can be added to your Nginx log file in the normal way.

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

This header follows the convention set by other HTTP cache servers. It indicates
simply `HIT` or `MISS` and the host name in question, preserving upstream values
when more than one cache server is in play.

If a resource is considered not cacheable, the `X-Cache` header will not be
present in the response.

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
