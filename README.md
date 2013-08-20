# Ledge

A [Lua](http://www.lua.org) module for [OpenResty](http://openresty.org), providing scriptable HTTP cache (edge) functionality for [Nginx](http://nginx.org), using [Redis](http://redis.io) as the cache / metadata store. 

The aim is to provide an efficient and extensible RFC compliant caching HTTP proxy server, including clear expressive configuration and event handling via Lua scripting.

## Status

This library is considered experimental and under active development, functionality may change without much notice.

[![Build Status](https://travis-ci.org/pintsized/ledge.png?branch=master)](https://travis-ci.org/pintsized/ledge)

### Features

* RFC 2616 compliant proxying and caching based on policies derived from HTTP request and response headers (please [raise an issue](https://github.com/pintsized/ledge/issues) if you spot a case we haven't covered).
* Cache items and metadata stored in [Redis](http://redis.io).
* Redis automatic failover with [Sentinel](http://redis.io/topics/sentinel).
* Mechanisms to override cache policies at various stages using Lua script.
* ESI support:
	* Variable substitution (strings only currently).
	* Comments removal.
	* `<esi:remove>` tags removed.
	* `<esi:include>` fetched non-blocking and in parallel if mutiple fragments are present (relative URIs only currently, see [this workaround](#absolute-uris).
	* Fragments properly affect downstream cache lifetime / revalidation for the parent resource.
* End-to-end revalidation (specific and unspecified).
* Offline modes (bypass, avoid).
* Serving stale content.
* Background revalidation.
* Collapsed forwarding (concurrent similar requests collapsed into a single upstream request).
* Caching POST responses (servable to subsequent GET / HEAD requests).
* Squid-like PURGE requests to remove resources from cache.

### Limitations

Beware of blindly caching large response bodies (videos etc). This could cause excessive memory usage spikes in Nginx, and obviously fill up your Redis instance, potentially forcing evictions. There are a few ideas being kicked around to mitigate this, including adding a streaming API to `ngx.location.capture`. Generally though, massive files don't suit cache so well since they tend to be static and latency constraints give way to bandwidth.

### Next up...

* Vary header support.
* The large response body problem.


Please feel free to raise issues at [https://github.com/pintsized/ledge/issues](https://github.com/pintsized/ledge/issues).

## Basic usage

Ledge can be used to cache any defined `location` blocks in Nginx, the most typical case being one which uses the [proxy module](http://wiki.nginx.org/HttpProxyModule), allowing you to cache upstream resources. The idea being that your actual resources are defined as `internal` locations, and a Ledge enabled location is invoked in their place. 

Simply create an instance of the module during `init_by_lua`, and then instruct Ledge to handle the response with one or more `content_by_lua` directive(s), each potentially containing their own bespoke configuration without risk of collision.

### Simple example

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
            content_by_lua 'ledge:run()';
        }

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
}
```

## Configuration and scripting

Out of the box Ledge will do more than just blindly cache things. It does its best to honour the (suprisingly complex on closer inspection) RFC suggestions and requirements for effective caching, including properly responding to cache control mechanisms in the request and response headers, which provide the tools for local revalidation, end-to-end revalidation, serving of stale resources and more.

Sometimes however, we want more flexibility for cache behaviours. Perhaps the origin is having problems, and needs extra cache protection. Or perhaps the origin is running on old tech, with poor support for HTTP caching in the first place.

### Example of scripted configuration

```nginx
http {
    init_by_lua '
        ledge_mod = require "ledge.ledge"
        ledge = ledge_mod:new()
        
        -- Options made here affect all uses of the module, and are only loaded once.
        
        ledge:config_set("redis_hosts", {
            { host = "127.0.0.1", port = 6380 }
        })
        ledge:config_set("redis_database", 3)
    ';

    server {
        listen 80;
        server_name example.com;

        location / {
            content_by_lua '
            	-- Our origin doesn't set cache headers, so we'll add them when we've fetched.
            	-- By adding "Last-Modified" clients will subsequently send conditional requests,
            	-- allowing Ledge to respond "304 Not Modified" without transferring the body.
            	
            	ledge:bind("origin_fetched", function(res)
				    res.header["Cache-Control"] = "max-age=3600"
				    res.header["Last-Modified"] = ngx.http_time(ngx.time())
				end)
            	
            	ledge:run()
            ';
        }
        
        # User profile area
        location /profile {
        	content_by_lua '
        		-- This location can't be cached, but it has ESI fragments which can be.
        		
        		ledge:config_set("enable_esi", true)
        		ledge:run()
        	';
        }
        
        # User profile ESI fragments
        location /profile_fragments {
        	content_by_lua '
        		-- These fragments can be cached for a day
        		
        		ledge:bind("origin_fetched", function(res)
				    res.header["Cache-Control"] = "max-age=86400"
				    res.header["Last-Modified"] = ngx.http_time(ngx.time())
				end)
				
				-- But they are delivered from a different server
				
				ledge:config_set("origin_location", "/__ledge_esi")
				
				-- Also, they may be requested over HTTPS, but the content is the same over HTTP.
				-- So lets avoid splitting the cache by ommitting "scheme".
				
				ledge:config_set("cache_key_spec", {
				    --ngx.var.scheme,
				    ngx.var.host,
				    ngx.var.uri,
				    ngx.var.args
				})
			'
		}

        location /__ledge_origin {
			internal;
	        # As Above
		}
		
		location /__ledge_esi {
			internal;
			# Some proxy to somewhere else...
		}
    }
}
```

## Installation

Download and install:

* [Redis](http://redis.io/download) >= 2.6.x
* [OpenResty](http://openresty.org/) >= 1.2.7.x

Review the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation on how to run Lua code in Nginx.

Clone this repo into a path defined by [lua_package_path](http://wiki.nginx.org/HttpLuaModule#lua_package_path) in `nginx.conf`.

Note: You should enable the [lua_check_client_abort](http://wiki.nginx.org/HttpLuaModule#lua_check_client_abort) directive to avoid ophaned connections to both the origin and Redis.

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

#### redis_hosts

*Default:* `{ { host = "127.0.0.1", port = 6379, socket = nil, password = nil } }`

A table of host tables, which will be tried in order. If a socket is supplied, this will overide host/port settings.

Both IP addresses and domain names can be used. In case of domain names, the Nginx core's dynamic resolver must be configured in your nginx.conf, e.g:

```nginx
resolver 8.8.8.8;  # use Google's public DNS nameserver
```

#### redis_database

*Default:* `0`

#### redis_timeout

*Default:* `100ms`

If set to `nil`, ngx_lua defaults to *60s*, overridable per worker process by using the `lua_socket_read_timeout` directive.

#### redis_keepalive_timeout

*Default:* `nil`

ngx_lua defaults to *60s*, overridable per worker process by using the `lua_socket_keepalive_timeout` directive.

#### redis_keepalive_pool_size

*Default:* `nil`

ngx_lua defaults to *30*, overridable per worker process by using the `lua_socket_pool_size` directive.


#### redis_use_sentinel

*Default:* `false`

Use Sentinel to obtain the details of a Redis server to be used. Please be sure to [read these docs](http://redis.io/topics/sentinel) in order to understand the capabilities and behaviours of Sentinel.

#### redis_sentinels

*Default:* `empty table`

Provide a table of Sentinel hosts to try in order. Once connected Ledge will ask Sentinel for a master to use. If the master is down, it will try to connect to a slave instead (where writes will fail).

#### redis_master_name

*Default:* `mymaster`

The name of the master to use. Again, refer to the [Sentinel docs](http://redis.io/topics/sentinel) for an explanation.

#### cache_key_spec

Overrides the cache key spec. This allows you to abstract certain items for great hit rates (at the expense of collisons), for example.

The default spec is:

```lua
{
    ngx.var.scheme,
    ngx.var.host,
    ngx.var.uri,
    ngx.var.args
}
```

Which will generate cache keys in Redis such as:

```
ledge:cache_obj:http:example.com:/about
ledge:cache_obj:http:example.com:/about:p=2&q=foo
```

If you're doing SSL termination at Nginx and your origin pages look the same for HTTPS and HTTP traffic, you could simply provide a cache key spec omitting `ngx.car.scheme`, to avoid splitting the cache.

Another case might be to use a hash algorithm for the args, if you're worried about cache keys getting too long (not a problem for Redis, but potentially for network and storage).

```lua
ledge:config_set("cache_key_spec", {
    --ngx.var.scheme,
    ngx.var.host,
    ngx.var.uri,
    ngx.md5(ngx.var.args)
})
```

#### keep_cache_for

*Default:* `30 days`

Specifies how long cache items are retained regardless of their TTL. You can use the [volatile-lru](http://antirez.com/post/redis-as-LRU-cache.html) Redis configuration to evict the least recently used cache items when under memory pressure. Therefore this setting is really about serving stale content with `ORIGIN_MODE_AVOID` or `ORIGIN_MODE_BYPASS` set.

#### max_stale

*Default:* `nil`

Specifies, in seconds, how far past expiry to serve cached content.
If set to `nil` then determine this from the `Cache-Control: max-stale=xx` request header.

WARNING: Any setting other than `nil` violates the HTTP spec.

#### stale_if_error

*Default:* `nil`

Specifies, in seconds, how far past expiry to serve cached content if the origin returns an error.
If set to `nil` then determine this from the `Cache-Control: stale-if-error=xx` request header.

#### background_revalidate

*Default:* `false`

Enables or disables revalidating requests served from stale in the background.

Note: This blocks processing the next request on the same *connection* until the background request has completed

#### enable_esi

*Default:* `false`

Enables ESI processing. The processor will strip comments labelled as `<!--esi ... -->`, remove items marked up with `<esi:remove>...</esi:remove>`, and fetch / include fragments marked up with `<esi:include src="/fragment_uri" />`. For example:

```xml
<esi:remove>
  <a href="/link_to_resource_for_non_esi">Link to resource</a>
</esi:remove>
<!--esi
<esi:include src="/link_to_resource_fragment?$(QUERY_STRING)" />
-->
```

In the above case, with ESI disabled the client will display a link to the embedded resource. With ESI enabled, the link will be removed, as well as the comments around the `<esi:include>` tag. The fragment `src` URI will be fetched (non-blocking and in parallel if multiple fragments are present), and the `<esi:include>` tag will be replaced with the resulting body. Note the ESI variable substitution for `$(QUERY_STRING)`, allowing you to proxy the parent resource parameters to fragments if required.

The processor runs ESI instruction detection on the slow path (i.e. when saving to cache), so only instructions which are present are processed on cache HITs. If nothing was detected during saving, enabling ESI will have no performance impact on regular serving of cache items.

##### Absolute URIs #####
Currently fragments to be included must be relative URIs. A workaround is to define a relative URI prefix which you pick up in your Nginx config, proxying to an additional origin.

#### enable_collapsed_forwarding

*Default:* `false`

With this enabled, Ledge will attempt to collapse similar origin requests for known (previously) cacheable resources into a single upstream request. Subsequent concurrent requests for the same resource will wait for the primary request, and then serve the newly cached content. 

This is useful in reducing load at the origin if requests are expensive. The longer the origin request, the more useful this is, since the greater the chance of concurrent requests.

Ledge wont collapse requests for resources that it hasn't seen before and weren't cacheble last time. If the resource has become non-cacheable since the last requet, the waiting requests will go to the origin themselves (having waited on the first request to find this out).

#### collapsed_forwarding_window

*Default:* `60000`ms

When collapsed forwarding is enabled, if a fatal error occurs during the origin request, the collapsed requests may never receive the response they are waiting for. This setting puts a limit on how long they will wait, and how long before new requests will decide to try the origin for themselves. 

If this is set shorter than your origin takes to respond, then you may get more upstream requests than desired. Fatal errors (server reboot etc) may result in hanging connections for up to the maximum time set. Normal errors (such as upstream timeouts) work independently of this setting.

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

## Protecting purge requests

Ledge will respond to requests using the (fake) HTTP method `PURGE`. If the resource exists it will be deleted and Ledge will exit with `200 OK`. If the resource doesn't exists, it will exit with `404 Not Found`.

This is mostly useful for internal tools which expect to work with Squid, and you probably want to restrict usage in some way.

```nginx
limit_except GET POST PUT DELETE {
  allow  127.0.0.1;
  deny   all;
}
```

## Logging

For cacheable responses, Ledge will add headers indicating the cache status. These can be added to your Nginx log file in the normal way.

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
