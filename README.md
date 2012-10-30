# Ledge

A [Lua](http://www.lua.org) module for [OpenResty](http://openresty.org), providing scriptable HTTP cache (edge) functionality for [Nginx](http://nginx.org), using [Redis](http://redis.io) as the cache / metadata store. 

The aim is to provide an efficient and extensible RFC compliant caching HTTP proxy server, including clear expressive configuration and event handling via Lua scripting.

## Status

The latest version is [v0.06](https://github.com/pintsized/ledge/tree/v0.06).

This library is considered experimental and under active development, functionality may change without much notice. However the tagged releases always pass tests and appear "stable", so checking out the latest tag should mean things work as advertised.

### Features

* RFC 2616 compliant proxying and caching based on policies derived from HTTP request and response headers (please [raise an issue](https://github.com/pintsized/ledge/issues) if you spot a case we haven't covered).
* Cache items and metadata stored in [Redis](http://redis.io).
* Mechanisms to override cache policies at various stages using Lua script.
* Basic ESI support:
	* Comments removal
	* `<esi:remove>`
	* `<esi:include>` fetched non-blocking and in parallel if mutiple fragments are present.
* End-to-end revalidation (specific and unspecified).
* Offline modes (bypass, avoid).

### TODO

* Configurable "stale" policies and background revalidate.
* Collapse forwarding.
* Caching POST responses (servable to subsequent GET / HEAD requests).
* Improved logging / stats.

Please feel free to raise issues at [https://github.com/pintsized/ledge/issues](https://github.com/pintsized/ledge/issues).

## Installation

Download and install:

* [Redis](http://redis.io/download) >= 2.4.14
* [OpenResty](http://openresty.org/) >= 1.2.1.9

Review the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation on how to run Lua code in Nginx.

Clone this repo into a path defined by [lua_package_path](http://wiki.nginx.org/HttpLuaModule#lua_package_path) in `nginx.conf`.

### Basic usage

Ledge can be used to cache any defined `location` blocks in Nginx, the most typical case being one which uses the [proxy module](http://wiki.nginx.org/HttpProxyModule), allowing you to cache upstream resources.

```nginx
server {
    listen 80;
    server_name example.com;
    
    location /__ledge_origin {
        internal;
        rewrite ^/__ledge_origin(.*)$ $1 break;
        proxy_set_header X-Real-IP  $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        proxy_read_timeout 30s;
        
        # Keep the origin Date header for more accurate Age calculation.
        proxy_pass_header Date;
        
        # http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html#sec14.38
        # If the response is being forwarded through a proxy, the proxy application MUST NOT
        # modify the Server response-header.
        proxy_pass_header Server;
        
        proxy_pass $scheme://YOUR.UPSTREAM.IP.ADDRESS:80;
    }
}
```

To place Ledge caching in front of everything on this server, create an instance of Ledge during `init_by_lua`, and then instruct Ledge to handle response within one or more `content_by_lua` directive(s).

```nginx
http {
    init_by_lua '
        ledge_mod = require "ledge.ledge"
        ledge = ledge_mod:new()
    ';

    server {
        listen 80;
        server_name example.com;

        location / {
            content_by_lua '
                ledge:run()
            ';
        }

        location /__ledge_origin {
            # As above
        }
    }
}
```

## Configuration options

You can configure Ledge behaviours and extend the functionality by calling API functions **before** running `ledge:run()`.

### ledge:config_set(param, value)

**Syntax:** `ledge:config_set(param, value)`

Sets a configuration option.

```lua
ledge:config_set("origin_location", "/__my_origin")
```

### ledge:config_get(param)

**Syntax:** `local value = ledge:config_get(param)`

Gets a configuration option.

### Options

#### origin_location

*Default:* `/__ledge_origin`

#### origin_mode

*Default:* `ORIGIN_MODE_NORMAL`

One of:

* `ORIGIN_MODE_NORMAL`
* `ORIGIN_MODE_AVOID`
* `ORIGIN_MODE_BYPASS`

`ORIGIN_MODE_NORMAL` proxies to the origin as expected. `ORIGIN_MODE_AVOID` will disregard cache headers and expiry to try and use the cache items wherever possible, avoiding the origin. This is similar to "offline_mode" in Squid. `ORIGIN_MODE_BYPASS` assumes the origin is down (for maintenance or otherwise), using cache where possible and exiting with `503 Service Unavailable` otherwise.

#### redis_host

*Default:* `127.0.0.1`

#### redis_port

*Default:* `6379`

#### redis_socket

*Default:* `nil`

`connect()` will use TCP by default, unless `redis_socket` is defined.

#### redis_database

*Default:* `0`

#### redis_timeout

*Default:* `nil`

ngx_lua defaults to *60s*, overridable per worker process by using the `lua_socket_read_timeout` directive. Only set this if you want fine grained control over Redis timeouts (rather than all cosocket connections).

#### redis_keepalive_timeout

*Default:* `nil`

ngx_lua defaults to *60s*, overridable per worker process by using the `lua_socket_keepalive_timeout` directive.

#### redis_keepalive_pool_size

*Default:* `nil`

ngx_lua defaults to *30*, overridable per worker process by using the `lua_socket_pool_size` directive.

#### cache_key_spec

Overrides the cache key spec. This allows you to abstract certain items for great hit rates (at the expense of collisons), for example.

The default spec is:

```lua
{
    ngx.var.request_method,
    ngx.var.scheme,
    ngx.var.host,
    ngx.var.uri,
    ngx.var.args
}
```

Which will generate cache keys in Redis such as:

```
ledge:cache_obj:HEAD:http:example.com:/about
ledge:cache_obj:HEAD:http:example.com:/about:p=2&q=foo
```

If you're doing SSL termination at Nginx and your origin pages look the same for HTTPS and HTTP traffic, you could simply provide a cache key spec omitting `ngx.car.scheme`, to avoid splitting the cache.

Another case might be to use a hash algorithm for the args, if you're worried about cache keys getting too long (not a problem for Redis, but potentially for network and storage).

```lua
ledge:config_set("cache_key_spec", {
    ngx.var.request_method,
    --ngx.var.scheme,
    ngx.var.host,
    ngx.var.uri,
    ngx.md5(ngx.var.args)
})
```

#### keep_cache_for

*Default:* `30 days`

Specifies how long cache items are retained regardless of their TTL. You can use the [volatile-lru](http://antirez.com/post/redis-as-LRU-cache.html) Redis configuration to evict the least recently used cache items when under memory pressure. Therefore this setting is really about serving stale content with `ORIGIN_MODE_AVOID` or `ORIGIN_MODE_BYPASS` set.

## Events

Ledge provides a set of events which are broadcast at the various stages of cacheing / proxying. A `response` table is passed through to functions bound to these events, providing the opportunity to manipulate the response as needed.

### ledge:bind(event_name, callback)

**Syntax:** `ledge:bind(event, function(res) end)`

Binds a user defined function to an event.

### Event names

#### cache_accessed

Broadcast when an item was found in cache and loaded into `res`.

#### origin_required

Broadcast when Ledge is about to proxy to the origin.

#### origin_fetched

Broadcast when the response was successfully fetched from the origin, but before it was saved to cache (and before __before_save__!). This is useful when the response must be modified to alter its cacheability. For example:

```lua
ledge:bind("origin_fetched", function(res)
	local ttl = 3600
	res.header["Cache-Control"] = "max-age="..ttl..", public"
	res.header["Pragma"] = nil
	res.header["Expires"] = ngx.http_time(ngx.time() + ttl)
end)
```

This blindly decides that a non-cacheable response can be cached. Probably only useful when origin servers aren't cooperating.

#### before_save

Broadcast when about to save a cacheable response.

#### response_ready

Ledge is finished and about to return. Last chance to jump in before rack sends the response.

## ESI

You can enable ESI processing with a single line of config during `content_by_lua`.

```lua
ledge:bind("response_ready", ledge.do_esi)
ledge:run()
```

The processor will strip comments labelled as `<!--esi ... -->`, remove items marked up with `<esi:remove>...</esi:remove>`, and fetch / include fragments marked up with `<esi:include src="/fragment_uri" />`. For example:

```xml
<esi:remove>
  <a href="http://www.example.com/link_to_resource_for_non_esi">Link to resource</a>
</esi:remove>
<!--esi
<esi:include src="http://example.com/link_to_resource_fragment" />
-->
```

In the above case, with ESI disabled the client will display a link to the embedded resource. With ESI enabled, the link will be removed, as well as the comments around the `<esi:include>` tag. The fragment `src` URI will be fetched (non-blocking and in parallel if multiple fragments are present), and the `<esi:include>` tag will be replaced with the resulting body.

Note that currently fragments to be included must be relative URIs. Absolute URIs and example config for proxying to arbitrary upstream services for fragments are on the short term roadmap.

## Logging / Debugging

For cacheable responses, Ledge will add headers indicating the cache status.

### X-Cache

This header follows the convention set by other HTTP cache servers. It indicates simply `HIT` or `MISS` and the host name in question, preserving upstream values when more than one cache server is in play. For example:

* `X-Cache: HIT from ledge.tld` A cache hit, with no (known) cache layer upstream.
* `X-Cache: HIT from ledge.tld, HIT from proxy.upstream.tld` A cache hit, also hit upstream.
* `X-Cache: MISS from ledge.tld, HIT from proxy.upstream.tld` A cache miss, but hit upstream.
* `X-Cache: MISS from ledge.tld, MISS from proxy.upstream.tld` Regenerated at the origin.

## Author

James Hurst <james@pintsized.co.uk>

## Licence

This module is licensed under the 2-clause BSD license.

Copyright (c) 2012, James Hurst <james@pintsized.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
