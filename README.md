# Ledge

An RFC compliant and [ESI](https://www.w3.org/TR/esi-lang) capable HTTP cache for [Nginx](http://nginx.org) / [OpenResty](https://openresty.org), backed by [Redis](http://redis.io).

Ledge can be utilised as a fast, robust and scalable alternative to Squid / Varnish etc, either installed standalone or integrated into an existing Nginx server or load balancer.

Moreover, it is particularly suited to applications where the origin is expensive or distant, making it desirable to serve from cache as optimistically as possible.


## Table of Contents

* [Installation](#installation)
* [Philosophy and Nomenclature](#philosophy-and-nomenclature)
    * [Cache keys](#cache-keys)
    * [Streaming design](#streaming-design)
    * [Collapsed forwarding](#collapsed-forwarding)
    * [Advanced cache patterns](#advanced-cache-patterns)
    * [Performance characteristics](#performance-characteristics)
* [Minimal configuration](#minimal-configuration)
* [Config systems](#config-systems)
* [Events system](#events-system)
* [Caching basics](#caching-basics)
* [Purging](#purging)
    * [Wildcard purging](#wildcard-purging)
* [Serving stale](#serving-stale)
* [Edge Side Includes](#edge-side-includes)
* [API](#api)
    * [ledge.configure](#ledgeconfigure)
    * [ledge.set_handler_defaults)(#ledgeset_handler_defaults)
    * [ledge.create_handler)(#ledgecreate_handler)
    * [ledge.create_worker)(#ledgecreate_worker)
    * [ledge.bind)(#ledgebind)
    * [handler.bind)(#handlerbind)
    * [handler.run)(#handlerrun)
    * [worker.run)(#workerrun)
    * [Handler configuration options](#handler-configuration-options)
    * [Events](#events)
* [Administration](#administration)
    * [Managing Qless](#managing-qless)
* [Licence](#licence)


## Installation

[OpenResty](http://openresty.org/) is a superset of [Nginx](http://nginx.org), bundling [LuaJIT](http://luajit.org/) and the [lua-nginx-module](https://github.com/openresty/lua-nginx-module) as well as many other things. Whilst it is possible to build all of these things into Nginx yourself, we recommend using the latest OpenResty.


### 1. Download and install:

* [OpenResty](http://openresty.org/) >= 1.11.x
* [Redis](http://redis.io/download) >= 2.8.x
* [LuaRocks](https://luarocks.org/)


### 2. Install Ledge using LuaRocks:

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


## Philosophy and Nomenclature

The central module is called `ledge`, and provides factory methods for creating `handler` instances (for handling a request) and `worker` instances (for running background tasks). The `ledge` module is also where global configuration is managed.

A `handler` is short lived. It is typically created at the beginning of the Nginx `content` phase for a request, and when its `run()` method is called, takes responsibility for processing the current request and delivering a response. When `run()` has completed, HTTP status, headers and body will have been delivered to the client.

A `worker` is long lived, and there is one per Nginx worker process. It is created when Nginx starts a worker process, and dies when the Nginx worker dies. The `worker` pops queued background jobs and processes them.

An `upstream` is the only thing which must be manually configured, and points to another HTTP host where actual content lives. Typically one would use DNS to resolve client connections to the Nginx server running Ledge, and tell Ledge where to fetch from with the `upstream` configuration. As such, Ledge isn't designed to work as a forwarding proxy.

[Redis](http://redis.io) is used for much more than cache storage. We rely heavily on its data structures to maintain cache `metadata`, as well as embedded Lua scripts for atomic task management and so on. By default, all cache body data and `metadata` will be stored in the same Redis instance. The location of cache `metadata` is global, set when Nginx starts up.

Cache body data is handled by the `storage` system, and as mentioned, by default shares the same Redis instance as the `metadata`. However, `storage` is abstracted via a driver system making it possible to store cache body data in a separate Redis instance, or a group of horizontally scalable Redis instances via a [proxy](https://github.com/twitter/twemproxy), or to roll your own `storage` driver, for example targeting PostreSQL or even simply a filesystem. It's perhaps important to consider that by default all cache storage uses Redis, and as such is bound by system memory.


### Cache keys

A goal of any caching system is to safely maximise the HIT potential. That is, normalise factors which would split the cache wherever possible, in order to share as much cache as possible.

This is tricky to generalise, and so by default Ledge puts sane defaults from the request URI into the cache key, and provides a means for this to be customised by altering the [cache\_key\_spec](#cache_key_spec).

URI arguments are sorted alphabetically by default, so `http://example.com?a=1&b=2` would hit the same cache entry as `http://example.com?b=2&a=1`.


### Streaming design

HTTP response sizes can be wildly different, sometimes tiny and sometimes huge, and it's not always possible to know the total size up front.

To guarantee predictable memory usage regardless of response sizes Ledge operates a streaming design, meaning it only ever operates on a single `buffer` per request at a time. This is equally true when fetching upstream to when reading from cache or 
serving to the client request.

It's also true (mostly) when processing [ESI](#edge-size-includes) instructions, except for in the case where instructions are found to span multiple buffers. In this case, we continue buffering until a complete instruction can be understood, up to a [configurable limit](#esi_max_size).

This streaming design also improves latency, since we start serving the first `buffer` to the client request as soon as we're done with it, rather than fetching and saving an entire resource prior to serving. The `buffer` size can be [tuned](#buffer_size) even on a per `location` basis.


### Collapsed forwarding

By default, Ledge will attempt to collapse concurrent origin requests for known (previously) cacheable resources into a single upstream request. That is, if an upstream request for a resource is in progress, subsequent concurrent requests for the same resource will not bother the upstream, and instead wait for the first request to finish.

This is particularly useful to reduce upstream load if a spike of traffic occurs for expired and expensive content (since the chances of concurrent requests is higher on slower content).


### Advanced cache patterns

Beyond standard RFC compliant cache behaviours, Ledge has many features designed to maximise cache HIT rates and to reduce latency for requests. See the sections on [Edge Side Include](#edge-side-includes), [serving stale](#serving-stale) and [revalidating on purge](#purging) for more information.


## Minimal configuration

Assuming you have Redis running on `localhost:6379`, and your upstream is at `localhost:8080`, add the following to the `nginx.conf` file in your OpenResty installation.

```lua
http {
    if_modified_since Off;
    lua_check_client_abort On;
    
    init_by_lua_block {
        require("ledge").configure({
            redis_connector_params = {
                url = "redis://127.0.0.1:6379/0",
            },
        })
        
        require("ledge").set_handler_defaults({
            upstream_host = "127.0.0.1",
            upstream_port = 8080,
        })
    }

    init_worker_by_lua_block {
        require("ledge").create_worker():run()
    }

    server {
        server_name example.com;
        listen 80;

        location / {
            content_by_lua_block {
                require("ledge").create_handler():run()
            }
        }
    }
}
```


## Config systems

There are four different layers to the configuration system. Firstly there is the main [Redis config](#configure) and [handler defaults](#set_handler_defaults) config, which are global and must be set during the Nginx `init` phase.

Beyond this, you can specify [handler instance config](#create_handler) on an Nginx `location` block basis, and finally there are some performance tuning config options for the [worker](#create_worker) instances.

In addition, there is an [events system](#events-system) for binding Lua functions to mid-request events, proving opportunities to dynamically alter configuration.



## Events system

Ledge makes most of its decisions based on the content it is working with. HTTP request and response headers drive the semantics for content delivery, and so rather than having countless configuration options to change this, we instead provide opportunities to alter the given semantics when necessary.

For example, if an `upstream` fails to set a long enough cache expiry, rather than inventing an option such as "extend\_ttl", we instead would `bind` to the `after_upstream_request` event, and adjust the response headers to include the ttl we're hoping for.

```lua
handler:bind("after_upstream_request", function(res)
    res.header["Cache-Control"] = "max-age=86400"
end)
```

This particular event fires after we've fetched upstream, but before Ledge makes any decisions about whether the content can be cached or not. Once we've adjustead our headers, Ledge will read them as if they came from the upstream itself.

Note that multiple functions can be bound to a single event, either globally or per handler, and they will be called in the order they were bound. There is also currently no means to inspect which functions have been bound, or to unbind them.


### Binding globally

Binding a function globally means it will fire for the given event, on all requests. This is perhaps useful if you have many different `location` blocks, but need to always perform the same logic.

```lua
init_by_lua_block {
    require("ledge"):bind("before_serve", function(res)
        res.header["X-Foo"] = "bar"   -- always set X-Foo to bar
    end)
}
```

### Binding to handlers

More commonly, we just want to alter behaviour for a given Nginx `location`. 

```lua
location /foo_location {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        
        handler:bind("before_serve", function(res)
            res.header["X-Foo"] = "bar"   -- only set X-Foo for this location
        end)
        
        handler:run()
    }
}
```

### Performance implications

Writing simple logic for events is not expensive at all (and in many cases will be JIT compiled). If you need to consult service endpoints during an event then obviously consider that this will affect your overall latency, and make sure you do everything in a **non-blocking** way, e.g. using [cosockets](https://github.com/openresty/lua-nginx-module#ngxsockettcp) provided by OpenResty, or a driver based upon this.

If you have lots of event handlers, consider that creating closures in Lua is relatively expensive. A good solution would be to make your own module, and pass the defined functions in.

```lua
location /foo_location {
    content_by_lua_block {
        local handler = require("ledge").create_handler()
        handler:bind("before_serve", require("my.handler.hooks").add_foo_header)
        handler:run()
    }
}
```


## Caching basics

For normal HTTP caching operation, no additional configuration is required. If the HTTP response indicates the resource can be cached, then it will cache it. If the HTTP request indicates it accepts cache, it will be served cache. Note that these two conditions aren't mutually exclusive - a request could specify `no-cache`, and this will indeed trigger a fetch upstream, but if the response is cacheable then it will be saved and served to subsequent cache-accepting requests.

For more information on the myriad factors affecting this, including end-to-end revalidation and so on, please refer to [RFC 7234](https://tools.ietf.org/html/rfc7234).

The goal is to be 100% RFC compliant, but with some extensions to allow more agressive caching in certain cases. If something doesn't work as you expect, please do feel free to [raise an issue](https://github.com/pintsized/ledge).


## Purging

To manually invalidate a cache item (or purge), we support the non-standard `PURGE` method familiar to users of Squid. Send a HTTP request to the URI with the method set, and Ledge will attempt to invalidate the item, returing status `200` on success and `404` if the URI was not found in cache, along with a JSON body for more details.

`$> curl -X PURGE -H "Host: example.com" http://cache.example.com/page1 | jq .`

```json
{
    "purge_mode": "invalidate",
    "result": "nothing to purge"
}
```

There are three purge modes, selectable by setting the `X-Purge` request header with one or more of the following values:

* `invalidate`: (default) marks the item as expired, but doesn't delete anything.
* `delete`: hard removes the item from cache
* `revalidate`: invalidates but then schedules a background revalidation to re-prime the cache.

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

Background revalidation jobs can be tracked in the qless metadata. See [managing qless](#managing-qless) for more information.

In general, `PURGE` is considered an administration task and probably shouldn't be allowed from the internet. Consider limiting it by IP address for example:

```nginx
limit_except GET POST PUT DELETE {
    allow   127.0.0.1;
    deny    all;
}
```

### Wildcard purging

Wildcard (\*) patterns are also supported in `PURGE` URIs, which will always return a status of `200` and a JSON body detailing a background job. Wildcard purges involve scanning the entire keyspace, and so can take a little while. See [keyspace\_scan\_count](#keyspace_scan_count) for tuning help.

In addition, the `X-Purge` mode will propagate to all URIs purged as a result of the wildcard, making it possible to trigger site / section wide revalidation for example. Be careful what you wish for.

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


## Serving stale

Content is considered "stale" when its age is beyond its TTL. However, depending on the value of [keep_cache_for](#keep_cache_for) (which defaults to 1 month), we don't actually expire content in Redis straight away.

This allows us to implement the stale cache control extensions described in [RFC5861](https://tools.ietf.org/html/rfc5861), which provides request and response header semantics for describing how stale something can be served, when it should be revalidated in the background, and how long we can serve stale content in the event of upstream errors.

This can be very effective in ensuring a fast user experience. For example, if your content has a genuine `max-age` of 24 hours, consider changing this to 1 hour, and adding `stale-while-revalidate` for 23 hours. The total TTL is therefore the same, but the first request after the first hour will trigger backgrounded revalidation, extending the TTL for a further 1 hour + 23 hours.

If your origin server cannot be configured in this way, you can always override by [binding](#events) to the `before_save` event.

```lua
handler:bind("before_save", function(res)
    -- Valid for 1 hour, stale-while-revalidate for 23 hours, stale-if-error for three days
    res.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=82800, stale-if-error=259200"
end)
```

In other words, set the TTL to the highest comfortable frequency of requests at the origin, and `stale-while-revalidate` to the longest comfortable TTL, to increase the chances of background revalidation occurring. Note that the first stale request will obviously get stale content, and so very long values can result in very out of data content for one request.

All stale behaviours are constrained by normal cache control semantics. For example, if the origin is down, and the response could be served stale due to the upstream error, but the request contains `Cache-Control: no-cache` or even `Cache-Control: max-age=60` where the content is older than 60 seconds, they will be served the error, rather than the stale content.


## Edge Side Includes

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

### Enabling ESI

Note that simply [enabling](#esi_enabled) ESI might not be enough. We also check the [content type](#esi_content_types) against the allowed types specified, but more importantly ESI processing is contingent upon the [Edge Architecture Specification](https://www.w3.org/TR/edge-arch/). When enabled, Ledge will advertise capabilities upstream with the `Surrogate-Capability` request header, and expect the upstream response to include a `Surrogate-Control` header delegating ESI processing to Ledge.

If your upstream is not ESI aware, a common approach is to bind to the [after\_upstream\_request](#after_upstream_request) event in order to add the `Surrogate-Control` header manually. E.g.

```lua
handler:bind("after_upstream_request", function(res)
    -- Don't enable ESI on redirect responses
    -- Don't override Surrogate Control if it already exists
    local status = res.status
    if not res.header["Surrogate-Control"] and not (status > 300 and status < 303) then
        res.header["Surrogate-Control"] = 'content="ESI/1.0"'
    end
end)
```

Note that if ESI is processed, downstream cache-ability is automatically dropped since you don't want other intermediaries or browsers caching the result.

It's therefore best to only set `Surrogate-Control` for content which you know has ESI instructions. Whilst Ledge will detect the presence of ESI instructions when saving (and do nothing on cache HITs if no instructions are present), on a cache MISS it will have already dropped downstream cache headers before reading / saving the body. This is a side-effect of the [streaming design](#streaming-design).

### Regular expressions in conditions

In addition to the operators defined in the
[ESI specification](https://www.w3.org/TR/esi-lang), we also support regular
expressions in conditions (as string literals), using the `=~` operator.

```html
<esi:choose>
   <esi:when test="$(QUERY_STRING{name}) =~ '/james|john/i'">
      Hi James or John
   </esi:when>
</esi:choose>
```

Supported modifiers are as per the [ngx.re.\*](https://github.com/openresty/lua-nginx-module#ngxrematch) documentation.


### Custom ESI variables

In addition to the variables defined in the [ESI specification](https://www.w3.org/TR/esi-lang), it is possible to stuff custom variables into a special table before running Ledge.

```lua
content_by_lua_block {
   require("ledge").create_handler({
      esi_custom_variables = {
         messages = {
            foo = "bar",
         },
      },
   }):run()
}
```

```html
<esi:vars>$(MESSAGES{foo})</esi:vars>
```

### ESI Args

It can be tempting to use URI arguments to pages using ESI in order to change layout dynamically, but this comes at the cost of generating multiple cache items - one for each permutation of URI arguments.

ESI args is a neat feature to get around this, by using a configurable prefix, which defaults to `esi_`. URI arguments with this prefix are removed from the cache key and also from upstream requests, and instead stuffed into the `$(ESI_ARGS{foo})` variable for use in ESI, typically in conditions. That is, think of them as magic URI arguments which have meaning for the ESI processor only, and should never affect cacheability or upstream content generation.

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

If `$(ESI_ARGS)` is used without a field key, it renders the original query string arguments, e.g. `esi_foo=bar&esi_display_mode=summary`, URL encoded.


### Missing ESI features

The following parts of the
[ESI specification](https://www.w3.org/TR/esi-lang) are not supported, but could
be in due course if a need is identified.

* `<esi:inline>` not implemented (or advertised as a capability).
* No support for the `onerror` or `alt` attributes for `<esi:include>`. Instead, we "continue" on error by default.
* `<esi:try | attempt | except>` not implemented.
* The "dictionary (special)" substructure variable type for `HTTP_USER_AGENT` is not implemented.


## API

### ledge.configure

The `configure()` function provides Ledge with Redis connection details for all cache `metadata` and background jobs. This is global and cannot be specified or adjusted outside the Nginx `init` phase.

```lua
init_by_lua_block {
    require("ledge").configure({
        redis_connector_params = {
            url = "redis://mypassword@127.0.0.1:6380/3",
        }
        qless_db = 4,
    })
}
```

### ledge.set\_handler\_defaults

The `set_handler_defaults()` method overrides the default configuration used for all spawned request `handler` instances. This is global and cannot be specified or adjusted outside the Nginx `init` phase, but defaults can be overriden on a per `handler` basis.

```lua
init_by_lua_block {
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = 8080,
    })
}
```

### ledge.create\_handler

Config given to `ledge.create_handler()` will be merged with the defaults, allowing certain options to be adjusted on a per Nginx `location` basis.

```lua
server {
    server_name example.com;
    listen 80;

    location / {
        content_by_lua_block {
            require("ledge").create_handler({
                upstream_port = 8081,
            }):run()
        }
    }
}
```

### ledge.create\_worker

Background job queues can be run at varying amounts of concurrency per worker. See [managing qless](#managing-qless) for more details.

```lua
init_worker_by_lua_block {
    require("ledge").create_worker({
        interval = 1,
        gc_queue_concurrency = 1,
        purge_queue_concurrency = 2,
        revalidate_queue_concurrency = 5,
    }):run()
}
```

### ledge.bind

### handler.bind

### handler.run

### worker.run

### Handler configuration options

### Events

* [after_cache_read](#after_cache_read)
* [before_upstream_connect](#before_upstream_connect)
* [before_upstream_request](#before_upstream_request)
* [before_esi_inclulde_request"](#before_esi_include_request)
* [after_upstream_request](#after_upstream_request)
* [before_save](#before_save)
* [before_serve](#before_serve)
* [before_save_revalidation_data](#before_save_revalidation_data)

#### after_cache_read

syntax: `handler:bind("after_cache_read", function(res) -- end)`

params: `res` The cached `ledge.response` instance.

Fires directly after the response was successfully loaded from cache.


#### before_upstream_connect

syntax: `ledge:bind("before_upstream_connect", function(handler) -- end)`

params: `handler`. The current handler instance.

Fires before the default `handler.upstream_client` is created.  
Use to override the default `resty.http` client and provide a pre-connected client module compatible with `resty.httpc`


#### before_upstream_request

syntax: `ledge:bind("before_upstream_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to send to the
[httpc:request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform an upstream request.


#### before_esi_include_request

syntax: `ledge:bind("before_esi_include_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to be used for an ESI
include.

Fires when about to perform a HTTP request on behalf of an ESI include
instruction.


#### after_upstream_request

syntax: `ledge:bind("after_upstream_request", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when the status/headers have been fetched, but before it is stored.
Typically used to override cache headers before we decide what to do with this
response.

*Note: unlike `before_save` below, this fires for all fetched content, not just
cacheable content.*


#### before_save

syntax: `ledge:bind("before_save", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to save the response.


#### before_serve

syntax: `ledge:bind("before_serve", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to serve. Often used to modify downstream headers.


#### before_save_revalidation_data

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


## Administration

### Managing Qless


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
