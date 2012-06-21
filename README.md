# Ledge

A [Lua](http://www.lua.org) module for [OpenResty](http://openresty.org), providing scriptable HTTP cache (edge) functionality for Nginx.

It utilises [Redis](http://redis.io) as a storage backend, and depends on the [lua-resty-redis](https://github.com/agentzh/lua-resty-redis) module bundled with OpenResty as well as [lua-resty-rack](https://github.com/pintsized/lua-resty-rack), maintained separately.

## Status

This library is considered experimental and under active development, functionality may change without notice. However it is currently in production for a small number of sites and appears stable.

Please feel free to raise issues at [https://github.com/pintsized/ledge/issues](https://github.com/pintsized/ledge/issues).

## Installation

Download and install:

* [Redis](http://redis.io/download) >= 2.4.14
* [ngx_openresty](http://openresty.org/) >= 1.0.15.7

Review the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation on how to run Lua code in Nginx.

Clone this repo and [lua-resty-rack](https://github.com/pintsized/lua-resty-rack) into a path defined by `lua_package_path` in `nginx.conf` (see [http://wiki.nginx.org/HttpLuaModule#lua_package_path](http://wiki.nginx.org/HttpLuaModule#lua_package_path)

### Usage

In `nginx.conf`, first define your upstream server as a `location` block. Note from the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation that named locations such as @foo cannot be used due to a limitation in the Nginx core. Instead, use a regular location (we've been using `/__ledge/` as a prefix), and mark it as `internal`.

```nginx
server {
	listen 80;
	server_name example.com;
	
	location /__ledge/example.com {
		internal;
		rewrite ^/__ledge/example.com(.*)$ $1 break;
		proxy_set_header X-Real-IP  $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header Host $host;
		proxy_read_timeout 30s;
		proxy_pass $scheme://YOUR.UPSTREAM.IP.ADDRESS:80;
	}
}
```

You can of course use anything available to you in Nginx as your origin `location`, here we are using the proxy module to fetch from our origin server.

Finally create the `location` block (inside the same `server` block), and configure Ledge by installing it with `resty.rack`.

```nginx
location / {
	# NOTE: The following cache_key generation is currently required, but will likely go away in the next version.
	set $query_hash "";
	if ($is_args != "") {
	    set $query_hash $args;
	    set_sha1 $query_hash;
	}
	set $cache_key ledge:cache_obj:$request_method:$scheme:$host:$uri:$query_hash;
	
	content_by_lua '
		local rack = require "resty.rack"
		local ledge = require "ledge.ledge"
		
		rack.use(ledge, { proxy_location = "/__ledge/example.com" })
		rack.run()
	';
}
```

## Functions

You can configure Ledge behaviours and extend the functionality by calling API functions **before** running `rack.run()`.

### ledge.set(param, value, ...)

**Syntax:** `ledge.set(param, value, filter_table?)`

Sets a configuration option. If the third parameter is omitted, all requests will use the same configuration option. If however filter_table is supplied, it's possible to set the parameter only for matching requests.

```lua
ledge.set("max_stale_age", 3600, {
	match_uri = {
		{ "/some/path", 86400 },
	},
	match_header = {
		{ "Content-Type", "application/json", 60 },
	},
})
```

#### Filters

There are two filter types; `match_uri` and `match_header`. Both accept a Lua pattern as the first table element, for looser matching.


### ledge.get(param)

**Syntax:** `local value = ledge.get(param)`

Gets a configuration option.


### ledge.bind(event_name, callback)

**Syntax:** `ledge.bind(event, function(req, res) end)`

Binds a user defined function to an event. See below for details of event types.

The `req` and `res` parameters are documented in [lua-resty-rack](https://github.com/pintsized/lua-resty-rack). Ledge adds some additional convenience methods.

* `req.accepts_cache()`
* `res.cacheable()`
* `res.expires_timestamp()`
* `res.ttl()`

## Events

Ledge provides a set of events which are broadcast at the various stages of cacheing / proxying. The req/res environment is passed through functions bound to these events, providing the opportunity to manipulate the request or response as needed. For example:

```lua
ledge.bind("response_ready", function(req, res)
	res.header['X-Homer'] = "Doh!"
end)
```

The events currently available are:

#### cache_accessed

Broadcast when an item was found in cache and loaded into `res`.

#### origin_required

Broadcast when Ledge is about to proxy to the origin.

#### before_save

Broadcast when about to save a cacheable response.

#### origin_fetched

Broadcast when the response was successfully fetched from the origin, but before it was saved to cache (and before __before_save__!). This is useful when the response must be modified to alter its cacheability. For example:

```lua
ledge.bind("origin_fetched", function(req, res)
	local ttl = 3600
	res.header["Cache-Control"] = "max-age="..ttl..", public"
	res.header["Pragma"] = nil
	res.header["Expires"] = ngx.http_time(ngx.time() + ttl)
end)
```

This blindly decides that a non-cacheable response can be cached. Probably only useful when origin servers aren't cooperating.

#### response_ready

Ledge is finished and about to return. Last chance to jump in before rack sends the response.

## Configuration parameters

There are currently no available runtime configuration parameters (rendering `set()` and `get()` above temporarily pointless for all but user supplied callbacks). 

There were methods to control behvaiours such as serving stale content, which were removed during refactoring and will be added back shortly.

## Author

James Hurst <jhurst@squiz.co.uk>

## Licence

This module is licensed under the 2-clause BSD license.

Copyright (c) 2012, James Hurst <jhurst@squiz.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
