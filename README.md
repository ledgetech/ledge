# Ledge

A [Lua](http://www.lua.org) module for [OpenResty](http://openresty.org), providing scriptable HTTP cache (edge) functionality for Nginx.

It utilises [Redis](http://redis.io) as a storage backend, and depends on the `lua-resty-*` modules bundled with OpenResty as well as [lua-resty-rack](https://github.com/pintsized/lua-resty-rack).

## Status

This library is considered experimental and under active development, functionality may change without notice. However it is currently in production for a small number of sites and appears stable.

## Installation

Download and install:

* [Redis](http://redis.io/download) >= 2.4.14
* [ngx_openresty](http://openresty.org/) >= 1.0.15.7

Read and understand the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation on how to run Lua code in Nginx.

Install the contents of `lib` from both [lua-resty-rack](https://github.com/pintsized/lua-resty-rack) and **ledge** to a path contained defined by `lua_package_path` in `nginx.conf` (see [http://wiki.nginx.org/HttpLuaModule#lua_package_path](http://wiki.nginx.org/HttpLuaModule#lua_package_path)

Such as

```
/myproj/lualib/ledge/ledge.lua
/myproj/lualib/resty/rack.lua
/myproj/lualib/resty/rack/*.lua
```

Where `lua_package_path` in `nginx.conf` looks like

```
lua_package_path '/myproj/lualib/?.lua;;';
```

## Usage

In `nginx.conf`, first define your upstream server as an internal location. Note from the [lua-nginx-module](http://wiki.nginx.org/HttpLuaModule) documentation that named locations such as @foo cannot be used due to a limitation in the Nginx core. Instead, use a regular location (we've been using /__ledge as a prefix), and mark it as `internal`.

```
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

You can of course use anything available to you in Nginx as an upstream location, here we are using the proxy module to fetch from our origin server.

Create another location block where you wish caching to take place, and configure Ledge.

```
location / {
	# NOTE: The following configuration is currently required, but will likely go away in the next version.
	set $query_hash "";
	if ($is_args != "") {
	    set $query_hash $args;
	    set_sha1 $query_hash;
	}
	set $cache_key ledge:cache_obj:$scheme:$host:$uri:$query_hash;	
	
	content_by_lua '_
		local rack = require "resty.rack"
		local ledge = require "ledge.ledge"
		
		rack.use(ledge, { proxy_location = "/__ledge/example.com" })
		rack.run()
	';
}
```

## Author

James Hurst <jhurst@squiz.co.uk>

## Licence

Copyright (c) 2012, James Hurst <jhurst@squiz.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
