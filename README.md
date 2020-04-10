# Ledge

[![Build Status](https://travis-ci.org/ledgetech/ledge.svg?branch=master)](https://travis-ci.org/ledgetech/ledge)

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
* [Minimal configuration](#minimal-configuration)
* [Config systems](#config-systems)
* [Events system](#events-system)
* [Caching basics](#caching-basics)
* [Purging](#purging)
* [Serving stale](#serving-stale)
* [Edge Side Includes](#edge-side-includes)
* [API](#api)
    * [ledge.configure](#ledgeconfigure)
    * [ledge.set_handler_defaults](#ledgeset_handler_defaults)
    * [ledge.create\_handler](#ledgecreate_handler)
    * [ledge.create\_worker](#ledgecreate_worker)
    * [ledge.bind](#ledgebind)
    * [handler.bind](#handlerbind)
    * [handler.run](#handlerrun)
    * [worker.run](#workerrun)
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

[Back to TOC](#table-of-contents)


## Philosophy and Nomenclature

The central module is called `ledge`, and provides factory methods for creating `handler` instances (for handling a request) and `worker` instances (for running background tasks). The `ledge` module is also where global configuration is managed.

A `handler` is short lived. It is typically created at the beginning of the Nginx `content` phase for a request, and when its [run()](#handlerrun) method is called, takes responsibility for processing the current request and delivering a response. When [run()](#handlerrun) has completed, HTTP status, headers and body will have been delivered to the client.

A `worker` is long lived, and there is one per Nginx worker process. It is created when Nginx starts a worker process, and dies when the Nginx worker dies. The `worker` pops queued background jobs and processes them.

An `upstream` is the only thing which must be manually configured, and points to another HTTP host where actual content lives. Typically one would use DNS to resolve client connections to the Nginx server running Ledge, and tell Ledge where to fetch from with the `upstream` configuration. As such, Ledge isn't designed to work as a forwarding proxy.

[Redis](http://redis.io) is used for much more than cache storage. We rely heavily on its data structures to maintain cache `metadata`, as well as embedded Lua scripts for atomic task management and so on. By default, all cache body data and `metadata` will be stored in the same Redis instance. The location of cache `metadata` is global, set when Nginx starts up.

Cache body data is handled by the `storage` system, and as mentioned, by default shares the same Redis instance as the `metadata`. However, `storage` is abstracted via a [driver system](#storage_driver) making it possible to store cache body data in a separate Redis instance, or a group of horizontally scalable Redis instances via a [proxy](https://github.com/twitter/twemproxy), or to roll your own `storage` driver, for example targeting PostreSQL or even simply a filesystem. It's perhaps important to consider that by default all cache storage uses Redis, and as such is bound by system memory.

[Back to TOC](#table-of-contents)

### Cache keys

A goal of any caching system is to safely maximise the HIT potential. That is, normalise factors which would split the cache wherever possible, in order to share as much cache as possible.

This is tricky to generalise, and so by default Ledge puts sane defaults from the request URI into the cache key, and provides a means for this to be customised by altering the [cache\_key\_spec](#cache_key_spec).

URI arguments are sorted alphabetically by default, so `http://example.com?a=1&b=2` would hit the same cache entry as `http://example.com?b=2&a=1`.

[Back to TOC](#table-of-contents)

### Streaming design

HTTP response sizes can be wildly different, sometimes tiny and sometimes huge, and it's not always possible to know the total size up front.

To guarantee predictable memory usage regardless of response sizes Ledge operates a streaming design, meaning it only ever operates on a single `buffer` per request at a time. This is equally true when fetching upstream to when reading from cache or serving to the client request.

It's also true (mostly) when processing [ESI](#edge-size-includes) instructions, except for in the case where an instruction is found to span multiple buffers. In this case, we continue buffering until a complete instruction can be understood, up to a [configurable limit](#esi_max_size).

This streaming design also improves latency, since we start serving the first `buffer` to the client request as soon as we're done with it, rather than fetching and saving an entire resource prior to serving. The `buffer` size can be [tuned](#buffer_size) even on a per `location` basis.

[Back to TOC](#table-of-contents)

### Collapsed forwarding

Ledge can attempt to collapse concurrent origin requests for known (previously) cacheable resources into a single upstream request. That is, if an upstream request for a resource is in progress, subsequent concurrent requests for the same resource will not bother the upstream, and instead wait for the first request to finish.

This is particularly useful to reduce upstream load if a spike of traffic occurs for expired and expensive content (since the chances of concurrent requests is higher on slower content).

[Back to TOC](#table-of-contents)

### Advanced cache patterns

Beyond standard RFC compliant cache behaviours, Ledge has many features designed to maximise cache HIT rates and to reduce latency for requests. See the sections on [Edge Side Includes](#edge-side-includes), [serving stale](#serving-stale) and [revalidating on purge](#purging) for more information.

[Back to TOC](#table-of-contents)


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

[Back to TOC](#table-of-contents)


## Config systems

There are four different layers to the configuration system. Firstly there is the main [Redis config](#ledgeconfigure) and [handler defaults](#ledgeset_handler_defaults) config, which are global and must be set during the Nginx `init` phase.

Beyond this, you can specify [handler instance config](#ledgecreate_handler) on an Nginx `location` block basis, and finally there are some performance tuning config options for the [worker](#ledgecreate_worker) instances.

In addition, there is an [events system](#events-system) for binding Lua functions to mid-request events, proving opportunities to dynamically alter configuration.

[Back to TOC](#table-of-contents)


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

See the [events](#events) section for a complete list of events and their definitions.

[Back to TOC](#table-of-contents)

### Binding globally

Binding a function globally means it will fire for the given event, on all requests. This is perhaps useful if you have many different `location` blocks, but need to always perform the same logic.

```lua
init_by_lua_block {
    require("ledge").bind("before_serve", function(res)
        res.header["X-Foo"] = "bar"   -- always set X-Foo to bar
    end)
}
```

[Back to TOC](#table-of-contents)

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

[Back to TOC](#table-of-contents)

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

[Back to TOC](#table-of-contents)


## Caching basics

For normal HTTP caching operation, no additional configuration is required. If the HTTP response indicates the resource can be cached, then it will cache it. If the HTTP request indicates it accepts cache, it will be served cache. Note that these two conditions aren't mutually exclusive - a request could specify `no-cache`, and this will indeed trigger a fetch upstream, but if the response is cacheable then it will be saved and served to subsequent cache-accepting requests.

For more information on the myriad factors affecting this, including end-to-end revalidation and so on, please refer to [RFC 7234](https://tools.ietf.org/html/rfc7234).

The goal is to be 100% RFC compliant, but with some extensions to allow more agressive caching in certain cases. If something doesn't work as you expect, please do feel free to [raise an issue](https://github.com/pintsized/ledge).

[Back to TOC](#table-of-contents)


## Purging

To manually invalidate a cache item (or purge), we support the non-standard `PURGE` method familiar to users of Squid. Send a HTTP request to the URI with the method set, and Ledge will attempt to invalidate the item, returning status `200` on success and `404` if the URI was not found in cache, along with a JSON body for more details.

A purge request will affect all representations associated with the cache key, for example compressed and uncompressed responses separated by the `Vary: Accept-Encoding` response header will all be purged.

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

[Back to TOC](#table-of-contents)

### JSON API

A JSON based API is also available for purging cache multiple cache items at once.
This requires a `PURGE` request with a `Content-Type` header set to `application/json` and a valid JSON request body.

Valid parameters
 * `uris` - Array of URIs to purge, can contain wildcard URIs
 * `purge_mode` - As the `X-Purge` header in a normal purge request
 * `headers` - Hash of additional headers to include in the purge request

Returns a results hash keyed by URI or a JSON error response

`$> curl -X PURGE -H "Content-Type: Application/JSON" http://cache.example.com/ -d '{"uris": ["http://www.example.com/1", "http://www.example.com/2"]}' | jq .`

```json
{
  "purge_mode": "invalidate",
  "result": {
    "http://www.example.com/1": {
      "result": "purged"
    },
    "http://www.example.com/2":{
      "result": "nothing to purge"
    }
  }
}
```

[Back to TOC](#table-of-contents)

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

[Back to TOC](#table-of-contents)


## Serving stale

Content is considered "stale" when its age is beyond its TTL. However, depending on the value of [keep_cache_for](#keep_cache_for) (which defaults to 1 month), we don't actually expire content in Redis straight away.

This allows us to implement the stale cache control extensions described in [RFC5861](https://tools.ietf.org/html/rfc5861), which provides request and response header semantics for describing how stale something can be served, when it should be revalidated in the background, and how long we can serve stale content in the event of upstream errors.

This can be very effective in ensuring a fast user experience. For example, if your content has a genuine `max-age` of 24 hours, consider changing this to 1 hour, and adding `stale-while-revalidate` for 23 hours. The total TTL is therefore the same, but the first request after the first hour will trigger backgrounded revalidation, extending the TTL for a further 1 hour + 23 hours.

If your origin server cannot be configured in this way, you can always override by [binding](#events) to the [before_save](#before_save) event.

```lua
handler:bind("before_save", function(res)
    -- Valid for 1 hour, stale-while-revalidate for 23 hours, stale-if-error for three days
    res.header["Cache-Control"] = "max-age=3600, stale-while-revalidate=82800, stale-if-error=259200"
end)
```

In other words, set the TTL to the highest comfortable frequency of requests at the origin, and `stale-while-revalidate` to the longest comfortable TTL, to increase the chances of background revalidation occurring. Note that the first stale request will obviously get stale content, and so very long values can result in very out of date content for one request.

All stale behaviours are constrained by normal cache control semantics. For example, if the origin is down, and the response could be served stale due to the upstream error, but the request contains `Cache-Control: no-cache` or even `Cache-Control: max-age=60` where the content is older than 60 seconds, they will be served the error, rather than the stale content.

[Back to TOC](#table-of-contents)


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

[Back to TOC](#table-of-contents)

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

[Back to TOC](#table-of-contents)

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

[Back to TOC](#table-of-contents)

### Custom ESI variables

In addition to the variables defined in the [ESI specification](https://www.w3.org/TR/esi-lang), it is possible to provide run time custom variables using the [esi_custom_variables](#esi_custom_variables) handler config option.

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

[Back to TOC](#table-of-contents)

### ESI Args

It can be tempting to use URI arguments to pages using ESI in order to change layout dynamically, but this comes at the cost of generating multiple cache items - one for each permutation of URI arguments.

ESI args is a neat feature to get around this, by using a configurable [prefix](#esi_args_prefix), which defaults to `esi_`. URI arguments with this prefix are removed from the cache key and also from upstream requests, and instead stuffed into the `$(ESI_ARGS{foo})` variable for use in ESI, typically in conditions. That is, think of them as magic URI arguments which have meaning for the ESI processor only, and should never affect cacheability or upstream content generation.

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

[Back to TOC](#table-of-contents)


### Variable Escaping

ESI variables are minimally escaped by default in order to prevent user's injecting additional ESI tags or XSS exploits.

Unescaped variables are available by prefixing the variable name with `RAW_`. This should be used with care.

```html
# /esi/test.html?a=<script>alert()</script>
<esi:vars>
$(QUERY_STRING{a})     <!-- &lt;script&gt;alert()&lt;/script&gt; -->
$(RAW_QUERY_STRING{a}) <!--  <script>alert()</script> -->
</esi:vars>
```

[Back to TOC](#table-of-contents)

### Missing ESI features

The following parts of the [ESI specification](https://www.w3.org/TR/esi-lang) are not supported, but could be in due course if a need is identified.

* `<esi:inline>` not implemented (or advertised as a capability).
* No support for the `onerror` or `alt` attributes for `<esi:include>`. Instead, we "continue" on error by default.
* `<esi:try | attempt | except>` not implemented.
* The "dictionary (special)" substructure variable type for `HTTP_USER_AGENT` is not implemented.

[Back to TOC](#table-of-contents)


## API

### ledge.configure

syntax: `ledge.configure(config)`

This function provides Ledge with Redis connection details for all cache `metadata` and background jobs. This is global and cannot be specified or adjusted outside the Nginx `init` phase.

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

`config` is a table with the following options (unrecognised config will error hard on start up).

[Back to TOC](#table-of-contents)


#### redis_connector_params

`default: {}`

Ledge uses [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector) to handle all Redis connections. It simply passes anything given in `redis_connector_params` straight to [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector), so review the documentation there for options, including how to use [Redis Sentinel](https://redis.io/topics/sentinel).


#### qless_db

`default: 1`

Specifies the Redis DB number to store [qless](https://github.com/pintsized/lua-resty-qless) background job data.

[Back to TOC](#table-of-contents)


### ledge.set\_handler\_defaults

syntax: `ledge.set_handler_defaults(config)`

This method overrides the default configuration used for all spawned request `handler` instances. This is global and cannot be specified or adjusted outside the Nginx `init` phase, but these defaults can be overriden on a per `handler` basis. See [below](#handler-configuration-options) for a complete list of configuration options.

```lua
init_by_lua_block {
    require("ledge").set_handler_defaults({
        upstream_host = "127.0.0.1",
        upstream_port = 8080,
    })
}
```

[Back to TOC](#table-of-contents)


### ledge.create\_handler

syntax: `local handler = ledge.create_handler(config)`

Creates a `handler` instance for the current reqiest. Config given here will be merged with the defaults, allowing certain options to be adjusted on a per Nginx `location` basis.

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

[Back to TOC](#table-of-contents)


### ledge.create\_worker

syntax: `local worker = ledge.create_worker(config)`

Creates a `worker` instance inside the current Nginx worker process, for processing background jobs. You only need to call this once inside a single `init_worker` block, and it will be called for each Nginx worker that is configured.

Job queues can be run at varying amounts of concurrency per worker, which can be set by providing `config` here. See [managing qless](#managing-qless) for more details.

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

[Back to TOC](#table-of-contents)


### ledge.bind

syntax: `ledge.bind(event_name, callback)`

Binds the `callback` function to the event given in `event_name`, globally for all requests on this system. Arguments to `callback` vary based on the event. See [below](#events) for event definitions.

[Back to TOC](#table-of-contents)


### handler.bind

syntax: `handler:bind(event_name, callback)`

Binds the `callback` function to the event given in `event_name` for this handler only. Note the `:` in `handler:bind()` which differs to the global `ledge.bind()`.

Arguments to `callback` vary based on the event. See [below](#events) for event definitions.

[Back to TOC](#table-of-contents)


### handler.run

syntax: `handler:run()`

Must be called during the `content_by_lua` phase. It processes the current request and serves a response. If you fail to call this method in your `location` block, nothing will happen.

[Back to TOC](#table-of-contents)


### worker.run

syntax: `handler:run()`

Must be called during the `init_worker` phase, otherwise background tasks will not be run, including garbage collection which is very importatnt.

[Back to TOC](#table-of-contents)


### Handler configuration options

* [storage_driver](#storage_driver)
* [storage_driver_config](#storage_driver_config)
* [origin_mode](#origin_mode)
* [upstream_connect_timeout](#upstream_connect_timeout)
* [upstream_send_timeout](#upstream_send_timeout)
* [upstream_read_timeout](#upstream_read_timeout)
* [upstream_keepalive_timeout](#upstream_keepalive_timeout)
* [upstream_keepalive_poolsize](#upstream_keepalive_poolsize)
* [upstream_host](#upstream_host)
* [upstream_port](#upstream_port)
* [upstream_use_ssl](#upstream_use_ssl)
* [upstream_ssl_server_name](#upstream_ssl_server_name)
* [upstream_ssl_verify](#upstream_ssl_verify)
* [buffer_size](#buffer_size)
* [advertise_ledge](#buffer_size)
* [keep_cache_for](#buffer_size)
* [minimum_old_entity_download_rate](#minimum_old_entity_download_rate)
* [esi_enabled](#esi_enabled)
* [esi_content_types](#esi_content_types)
* [esi_allow_surrogate_delegation](#esi_allow_surrogate_delegation)
* [esi_recursion_limit](#esi_recursion_limit)
* [esi_args_prefix](#esi_args_prefix)
* [esi_custom_variables](#esi_custom_variables)
* [esi_max_size](#esi_max_size)
* [esi_attempt_loopback](#esi_attempt_loopback)
* [esi_vars_cookie_blacklist](#esi_vars_cookie_blacklist)
* [esi_disable_third_party_includes](#esi_disable_third_party_includes)
* [esi_third_party_includes_domain_whitelist](#esi_third_party_includes_domain_whitelist)
* [enable_collapsed_forwarding](#enable_collapsed_forwarding)
* [collapsed_forwarding_window](#collapsed_forwarding_window)
* [gunzip_enabled](#gunzip_enabled)
* [keyspace_scan_count](#keyspace_scan_count)
* [cache_key_spec](#cache_key_spec)
* [max_uri_args](#max_uri_args)


#### storage_driver

default: `ledge.storage.redis`

This is a `string` value, which will be used to attempt to load a storage driver. Any third party driver here can accept its own config options (see below), but must provide the following interface:

* `bool new()`
* `bool connect()`
* `bool close()`
* `number get_max_size()` *(return nil for no max)*
* `bool exists(string entity_id)`
* `bool delete(string entity_id)`
* `bool set_ttl(string entity_id, number ttl)`
* `number get_ttl(string entity_id)`
* `function get_reader(object response)`
* `function get_writer(object response, number ttl, function onsuccess, function onfailure)`

*Note, whilst it is possible to configure storage drivers on a per `location` basis, it is **strongly** recommended that you never do this, and consider storage drivers to be system wide, much like the main Redis config. If you really need differenet storage driver configurations for different locations, then it will work, but features such as purging using wildcards will silently not work. YMMV.*

[Back to TOC](#handler-configuration-options)


#### storage_driver_config

`default: {}`

Storage configuration can vary based on the driver. Currently we only have a Redis driver.

[Back to TOC](#handler-configuration-options)


##### Redis storage driver config

* `redis_connector_params` Redis params table, as per [lua-resty-redis-connector](https://github.com/pintsized/lua-resty-redis-connector)
* `max_size` (bytes), defaults to `1MB`
* `supports_transactions` defaults to `true`, set to false if using a Redis proxy.

If `supports_transactions` is set to `false`, cache bodies are not written atomically. However, if there is an error writing, the main Redis system will be notified and the overall transaction will be aborted. The result being potentially orphaned body entities in the storage system, which will hopefully eventually expire. The only reason to turn this off is if you are using a Redis proxy, as any transaction related commands will break the connection.

[Back to TOC](#handler-configuration-options)


#### upstream_connect_timeout

default: `1000 (ms)`

Maximum time to wait for an upstream connection (in milliseconds). If it is exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.

[Back to TOC](#handler-configuration-options)


#### upstream_send_timeout

default: `2000 (ms)`

Maximum time to wait sending data on a connected upstream socket (in milliseconds). If it is exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.

[Back to TOC](#handler-configuration-options)


#### upstream_read_timeout

default: `10000 (ms)`

Maximum time to wait on a connected upstream socket (in milliseconds). If it is exceeded, we send a `503` status code, unless [stale_if_error](#stale_if_error) is configured.

[Back to TOC](#handler-configuration-options)


#### upstream_keepalive_timeout

default: `75000`

[Back to TOC](#handler-configuration-options)


#### upstream_keepalive_poolsize

default: `64`

[Back to TOC](#handler-configuration-options)


#### upstream_host

default: `""`

Specifies the hostname or IP address of the upstream host. If a hostname is specified, you must configure the Nginx [resolver](http://nginx.org/en/docs/http/ngx_http_core_module.html#resolver) somewhere, for example:

```nginx
resolver 8.8.8.8;
```

[Back to TOC](#handler-configuration-options)


#### upstream_port

default: `80`

Specifies the port of the upstream host.

[Back to TOC](#handler-configuration-options)


#### upstream_use_ssl

default: `false`

Toggles the use of SSL on the upstream connection. Other `upstream_ssl_*` options will be ignored if this is not set to `true`.

[Back to TOC](#handler-configuration-options)


#### upstream_ssl_server_name

default: `""`

Specifies the SSL server name used for Server Name Indication (SNI). See [sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more information.

[Back to TOC](#handler-configuration-options)


#### upstream_ssl_verify

default: `true`

Toggles SSL verification. See [sslhandshake](https://github.com/openresty/lua-nginx-module#tcpsocksslhandshake) for more information.

[Back to TOC](#handler-configuration-options)


#### cache_key_spec

`default: cache_key_spec = { "scheme", "host", "uri", "args" },`

Specifies the format for creating cache keys. The default spec above will create keys in Redis similar to:

```
ledge:cache:http:example.com:/about::
ledge:cache:http:example.com:/about:p=2&q=foo:
```

The list of available string identifiers in the spec is:

* `scheme` either http or https
* `host` the hostname of the current request
* `port` the public port of the current request
* `uri` the URI (without args)
* `args` the URI args, sorted alphabetically

In addition to these string identifiers, dynamic parameters can be added to the cache key by providing functions. Any functions given must expect no arguments and return a string value.

```lua
local function get_device_type()
    -- dynamically work out device type
    return "tablet"
end

require("ledge").create_handler({
    cache_key_spec = {
        get_device_type,
        "scheme",
        "host",
        "uri",
        "args",
    }
}):run()
```

Consider leveraging vary, via the [before_vary_selection](#before_vary_selection) event, for separating cache entries rather than modifying the main `cache_key_spec` directly.

[Back to TOC](#handler-configuration-options)


#### origin_mode

default: `ledge.ORIGIN_MODE_NORMAL`

Determines the overall behaviour for connecting to the origin. `ORIGIN_MODE_NORMAL` will assume the origin is up, and connect as necessary.

`ORIGIN_MODE_AVOID` is similar to Squid's `offline_mode`, where any retained cache (expired or not) will be served rather than trying the origin, regardless of cache-control headers, but the origin will be tried if there is no cache to serve.

`ORIGIN_MODE_BYPASS` is the same as `AVOID`, except if there is no cache to serve we send a `503 Service Unavailable` status code to the client and never attempt an upstream connection.

[Back to TOC](#handler-configuration-options)


#### keep_cache_for

default: `86400 * 30 (1 month in seconds)`

Specifies how long to retain cache data past its expiry date. This allows us to serve stale cache in the event of upstream failure with [stale_if_error](#stale_if_error) or [origin_mode](#origin_mode) settings.

Items will be evicted when under memory pressure provided you are using one of the Redis [volatile eviction policies](http://redis.io/topics/lru-cache), so there should generally be no real need to lower this for space reasons.

Items at the extreme end of this (i.e. nearly a month old) are clearly very rarely requested, or more likely, have been removed at the origin.

[Back to TOC](#handler-configuration-options)


#### minimum_old_entity_download_rate

default: `56 (kbps)`

Clients reading slower than this who are also unfortunate enough to have started reading from an entity which has been replaced (due to another client causing a revalidation for example), may have their entity garbage collected before they finish, resulting in an incomplete resource being delivered.

Lowering this is fairer on slow clients, but widens the potential window for multiple old entities to stack up, which in turn could threaten Redis storage space and force evictions.

[Back to TOC](#handler-configuration-options)


#### enable_collapsed_forwarding

default: `false`

[Back to TOC](#handler-configuration-options)


#### collapsed_forwarding_window

When collapsed forwarding is enabled, if a fatal error occurs during the origin request, the collapsed requests may never receive the response they are waiting for. This setting puts a limit on how long they will wait, and how long before new requests will decide to try the origin for themselves.

If this is set shorter than your origin takes to respond, then you may get more upstream requests than desired. Fatal errors (server reboot etc) may result in hanging connections for up to the maximum time set. Normal errors (such as upstream timeouts) work independently of this setting.

[Back to TOC](#handler-configuration-options)


#### gunzip_enabled

default: `true`

With this enabled, gzipped responses will be uncompressed on the fly for clients that do not set `Accept-Encoding: gzip`. Note that if we receive a gzipped response for a resource containing ESI instructions, we gunzip whilst saving and store uncompressed, since we need to read the ESI instructions.

Also note that `Range` requests for gzipped content must be ignored - the full response will be returned.

[Back to TOC](#handler-configuration-options)


#### buffer_size

default: `2^16 (64KB in bytes)`

Specifies the internal buffer size (in bytes) used for data to be read/written/served. Upstream responses are read in chunks of this maximum size, preventing allocation of large amounts of memory in the event of receiving large files. Data is also stored internally as a list of chunks, and delivered to the Nginx output chain buffers in the same fashion.

The only exception is if ESI is configured, and Ledge has determined there are ESI instructions to process, and any of these instructions span a given chunk. In this case, buffers are concatenated until a complete instruction is found, and then ESI operates on this new buffer, up to a maximum of [esi_max_size](#esi_max_size).

[Back to TOC](#handler-configuration-options)


#### keyspace_scan_count

default: `1000`

Tunes the behaviour of keyspace scans, which occur when sending a PURGE request with wildcard syntax. A higher number may be better if latency to Redis is high and the keyspace is large.

[Back to TOC](#handler-configuration-options)


#### max_uri_args

default: `100`

Limits the number of URI arguments returned in calls to [ngx.req.get_uri_args()](https://github.com/openresty/lua-nginx-module#ngxreqget_uri_args), to protect against DOS attacks.

[Back to TOC](#handler-configuration-options)


#### esi_enabled

default: `false`

Toggles [ESI](http://www.w3.org/TR/esi-lang) scanning and processing, though behaviour is also contingent upon [esi_content_types](#esi_content_types) and [esi_surrogate_delegation](#esi_surrogate_delegation) settings, as well as `Surrogate-Control` / `Surrogate-Capability` headers.

ESI instructions are detected on the slow path (i.e. when fetching from the origin), so only instructions which are known to be present are processed on cache HITs.

[Back to TOC](#handler-configuration-options)


#### esi_content_types

default: `{ text/html }`

Specifies content types to perform ESI processing on. All other content types will not be considered for processing.

[Back to TOC](#handler-configuration-options)


#### esi_allow_surrogate_delegation

default: false

[ESI Surrogate Delegation](http://www.w3.org/TR/edge-arch) allows for downstream intermediaries to advertise a capability to process ESI instructions nearer to the client. By setting this to `true` any downstream offering this will disable ESI processing in Ledge, delegating it downstream.

When set to a Lua table of IP address strings, delegation will only be allowed to this specific hosts. This may be important if ESI instructions contain sensitive data which must be removed.

[Back to TOC](#handler-configuration-options)


#### esi_recursion_limit

default: 10

Limits fragment inclusion nesting, to avoid accidental infinite recursion.

[Back to TOC](#handler-configuration-options)


#### esi_args_prefix

default: "esi\_"

URI args prefix for parameters to be ignored from the cache key (and not proxied upstream), for use exclusively with ESI rendering logic. Set to nil to disable the feature.

[Back to TOC](#handler-configuration-options)


#### esi_custom_variables

defualt: `{}`

Any variables supplied here will be available anywhere ESI vars can be used evaluated. See [Custom ESI variables](#custom-esi-variables).

[Back to TOC](#handler-configuration-options)


#### esi_max_size

default: `1024 * 1024 (bytes)`

[Back to TOC](#handler-configuration-options)


#### esi_attempt_loopback

default: `true`

If an ESI subrequest has the same `scheme` and `host` as the parent request, we loopback the connection to the current
`server_addr` and `server_port` in order to avoid going over network.

[Back to TOC](#handler-configuration-options)


#### esi_vars_cookie_blacklist

default: `{}`

Cookie names given here will not be expandable as ESI variables: e.g. `$(HTTP_COOKIE)` or `$(HTTP_COOKIE{foo})`. However they
are not removed from the request data, and will still be propagated to `<esi:include>` subrequests.

This is useful if your client is sending a sensitive cookie that you don't ever want to accidentally evaluate in server output.

```lua
require("ledge").create_handler({
    esi_vars_cookie_blacklist = {
        secret = true,
        ["my-secret-cookie"] = true,
    }
}):run()
```

Cookie names are given as the table key with a truthy value, for O(1) runtime lookup.


[Back to TOC](#handler-configuration-options)


#### esi_disable_third_party_includes

default: `false`

`<esi:include>` tags can make requests to any arbitrary URI. Turn this on to ensure the URI domain must match the URI of the current request.

[Back to TOC](#handler-configuration-options)


#### esi_third_party_includes_domain_whitelist

default: `{}`

If third party includes are disabled, you can also explicitly provide a whitelist of allowed third party domains.

```lua
require("ledge").create_handler({
    esi_disable_third_party_includes = true,
    esi_third_party_includes_domain_whitelist = {
        ["example.com"] = true,
    }
}):run()
```

Hostnames are given as the table key with a truthy value, for O(1) lookup.

*Note; This behaviour was introduced in v2.2*

[Back to TOC](#handler-configuration-options)


#### advertise_ledge

default `true`

If set to false, disables advertising the software name and version, e.g. `(ledge/2.01)` from the `Via` response header.

[Back to TOC](#handler-configuration-options)


### Events

* [after_cache_read](#after_cache_read)
* [before_upstream_connect](#before_upstream_connect)
* [before_upstream_request](#before_upstream_request)
* [before_esi_inclulde_request"](#before_esi_include_request)
* [after_upstream_request](#after_upstream_request)
* [before_save](#before_save)
* [before_serve](#before_serve)
* [before_save_revalidation_data](#before_save_revalidation_data)
* [before_vary_selection](#before_vary_selection)

#### after_cache_read

syntax: `bind("after_cache_read", function(res) -- end)`

params: `res`. The cached response table.

Fires directly after the response was successfully loaded from cache.

The `res` table given contains:

* `res.header` the table of case-insenitive HTTP response headers
* `res.status` the HTTP response status code

*Note; there are other fields and methods attached, but it is strongly advised to never adjust anything other than the above*

[Back to TOC](#events)


#### before_upstream_connect

syntax: `bind("before_upstream_connect", function(handler) -- end)`

params: `handler`. The current handler instance.

Fires before the default `handler.upstream_client` is created, allowing a pre-connected HTTP client to be externally provided. The client must be API compatible with [lua-resty-http](https://github.com/pintsized/lua-resty-http). For example, using [lua-resty-upstream](https://github.com/hamishforbes/lua-resty-upstream) for load balancing.

[Back to TOC](#events)


#### before_upstream_request

syntax: `bind("before_upstream_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to send to the [request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform an upstream request.

[Back to TOC](#events)


#### before_esi_include_request

syntax: `bind("before_esi_include_request", function(req_params) -- end)`

params: `req_params`. The table of request params about to be used for an ESI include, via the [request](https://github.com/pintsized/lua-resty-http#request) method.

Fires when about to perform a HTTP request on behalf of an ESI include instruction.

[Back to TOC](#events)


#### after_upstream_request

syntax: `bind("after_upstream_request", function(res) -- end)`

params: `res` The response table.

Fires when the status / headers have been fetched, but before the body it is stored. Typically used to override cache headers before we decide what to do with this response.

The `res` table given contains:

* `res.header` the table of case-insenitive HTTP response headers
* `res.status` the HTTP response status code

*Note; there are other fields and methods attached, but it is strongly advised to never adjust anything other than the above*

*Note: unlike `before_save` below, this fires for all fetched content, not just cacheable content.*

[Back to TOC](#events)


#### before_save

syntax: `bind("before_save", function(res) -- end)`

params: `res` The response table.

Fires when we're about to save the response.

The `res` table given contains:

* `res.header` the table of case-insenitive HTTP response headers
* `res.status` the HTTP response status code

*Note; there are other fields and methods attached, but it is strongly advised to never adjust anything other than the above*

[Back to TOC](#events)


#### before_serve

syntax: `ledge:bind("before_serve", function(res) -- end)`

params: `res` The `ledge.response` object.

Fires when we're about to serve. Often used to modify downstream headers.

The `res` table given contains:

* `res.header` the table of case-insenitive HTTP response headers
* `res.status` the HTTP response status code

*Note; there are other fields and methods attached, but it is strongly advised to never adjust anything other than the above*

[Back to TOC](#events)


#### before_save_revalidation_data

syntax: `bind("before_save_revalidation_data", function(reval_params, reval_headers) -- end)`

params: `reval_params`. Table of revalidation params.

params: `reval_headers`. Table of revalidation HTTP headers.

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

[Back to TOC](#events)


#### before_vary_selection

syntax: `bind("before_vary_selection", function(vary_key) -- end)`

params: `vary_key` A table of selecting headers

Fires when we're about to generate the vary key, used to select the correct cache representation.

The `vary_key` table is a hash of header field names (lowercase) to values.
A field name which exists in the Vary response header but does not exist in the current request header will have a value of `ngx.null`.

```
Request Headers:
    Accept-Encoding: gzip
    X-Test: abc
    X-test: def

Response Headers:
    Vary: Accept-Encoding, X-Test
    Vary: X-Foo

vary_key table:
{
    ["accept-encoding"] = "gzip",
    ["x-test"] = "abc,def",
    ["x-foo"] = ngx.null
}
```

[Back to TOC](#events)


## Administration

### X-Cache

Ledge adds the non-standard `X-Cache` header, familiar to users of other caches. It indicates simply `HIT` or `MISS` and the host name in question, preserving upstream values when more than one cache server is in play.

If a resource is considered not cacheable, the `X-Cache` header will not be present in the response.

For example:

* `X-Cache: HIT from ledge.tld` *A cache hit, with no (known) cache layer upstream.*
* `X-Cache: HIT from ledge.tld, HIT from proxy.upstream.tld` *A cache hit, also hit upstream.*
* `X-Cache: MISS from ledge.tld, HIT from proxy.upstream.tld` *A cache miss, but hit upstream.*
* `X-Cache: MISS from ledge.tld, MISS from proxy.upstream.tld` *Regenerated at the origin.*

[Back to TOC](#table-of-contents)


### Logging

It's often useful to add some extra headers to your Nginx logs, for example

```
log_format ledge  '$remote_addr - $remote_user [$time_local] '
                  '"$request" $status $body_bytes_sent '
                  '"$http_referer" "$http_user_agent" '
                  '"Cache:$sent_http_x_cache"  "Age:$sent_http_age" "Via:$sent_http_via"'
                  ;

access_log /var/log/nginx/access_log ledge;
```

Will give log lines such as:

```
192.168.59.3 - - [23/May/2016:22:22:18 +0000] "GET /x/y/z HTTP/1.1" 200 57840 "-" "curl/7.37.1""Cache:HIT from 159e8241f519:8080"  "Age:724"

```
[Back to TOC](#table-of-contents)


### Managing Qless

Ledge uses [lua-resty-qless](https://github.com/pintsized/lua-resty-qless) to schedule and process background tasks, which are stored in Redis.

Jobs are scheduled for background revalidation requests as well as wildcard PURGE requests, but most importantly for garbage collection of replaced body entities.

That is, it's very important that jobs are being run properly and in a timely fashion.

Installing the [web user interface](https://github.com/hamishforbes/lua-resty-qless-web) can be very helpful to check this.

You may also wish to tweak the [qless job history](https://github.com/pintsized/lua-resty-qless#configuration-options) settings if it takes up too much space.


[Back to TOC](#table-of-contents)


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
