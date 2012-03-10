# Ledge (Lua - Edge)

An attempt at edge proxying and caching logic in Lua. Relies on [nginx](http://nginx.net), the [lua-nginx-module](https://github.com/chaoslawful/lua-nginx-module) for integrating Lua coroutines into the nginx event model via nginx subrequests, as well as [Redis](http://redis.io) as an upstream server to act as a cache backend.

## What is it?

The idea is to provide predictable tools around agressive edge caching, for cases where origin servers are distant, slow, or unreliable. Tools are/will be included to monitor cache objects about to expire, and prime them in advance (pledge) as well as thorough statistical analysis to help tune behaviours and weed out cache policy issues at the origin (sledge).

Configuration should be flexible and expressive as Lua code, allowing for behavioural filtering at run time (based on URIs or request headers) and advanced features such as ESI parsing.

It should also be very fast, if all goes well, owing to the stack that it's built on.

## What isn't it?

* A replacement for Squid. This will never do forward proxying, for example.
* An application server stack. You could do some pretty cool things with the nginx\_lua module I'm sure, but what I'm shooting for here is some caching code to cover the bases, leaving your code to be simple configuration hooks, modifying behaviours to suit your backends.
* Finished. A lot of the code still looks like pseudo stubs (or embarrassing hacks), but it is coming together slowly.

## Status

Experimental prototype. Not at all ready for production, currently still proving out the technology.

## Support / Contributing

All help, ideas, and bug reports are very much welcomed. Raise a ticket or email me at <jhurst@squiz.co.uk>.

## Installation

I hope to get some installation instructions that are actually accurate together soon. This is not exhaustive.

### ngx_openresty

Follow the instructions here: http://github.com/agentzh/ngx_openresty

For (even) better performance, compile --with-luajit

You'll also need the redis parser: https://github.com/agentzh/lua-redis-parser

### Redis

Download and install from http://redis.io/download

### nginx configuration

#### Lua package path

This is configured at the 'http' level of the nginx conf, not per server, and must be set to where you install ledge. e.g.

	# Ledge, followed by default (;;)
	lua_package_path '/home/me/ledge/?.lua;;';

#### Upstream servers

Also at the http level:

    # Upstream servers   
    upstream origin {
        server {YOUR_ORIGIN_IP}:80;  
    }

    upstream redis {   
        server localhost:6379;
        keepalive 1024 single;
    } 

	upstream redis_subscribe {
		server localhost:6379;
	}
	
#### Example server configuration

    server {
        listen       80;
        server_name  {YOUR_SERVER_NAME}; 
        access_log  logs/access.log  main;
		
        location / { 
            lua_need_request_body on; 

            # URIs and key specs.
            set $full_uri $scheme://$host$uri$is_args$args;
            set $relative_uri $uri$is_args$args;
            set $cache_key $full_uri;
            set_sha1 $cache_key;
            set $cache_key ledge:cache_obj:$cache_key;

            set $config_file 'ledge/conf/config.lua';

            # Nginx locations for Ledge to do I/O. 
            set $loc_redis '/__ledge/redis';
            set $loc_origin '/__ledge/origin';
            set $loc_wait_for_origin '/__ledge/wait_for_origin';

            # Auth stage
            # access_by_lua_file '/home/jhurst/prj/squiz_edge/ledge/handlers/auth.lua';

            # Content stage
            content_by_lua_file '/home/jhurst/prj/squiz_edge/ledge/handlers/content.lua';
        }   

        ### Internal (reserved) locations ###

    	# Proxy to origin server
    	location /__ledge/origin {
    		internal;
    		rewrite ^/__ledge/origin(.*)$ $1 break;
    		proxy_set_header X-Real-IP  $remote_addr;
    		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    		proxy_set_header Host $host;
			proxy_read_timeout 10s;
            proxy_redirect off;
			proxy_pass http://origin;
	    }   
		
		location /__ledge/wait_for_origin {
			internal;
	    	set_unescape_uri $channel $arg_channel;
       		redis2_raw_queries 2 "SUBSCRIBE $channel\r\n";

    		redis2_connect_timeout 200ms;
    		redis2_send_timeout 200ms;
    		redis2_read_timeout 60s;
       		redis2_pass redis_subscribe;
		}


        # Redis
        # Accepts a raw query as the "query" arg or POST body. Sending
        # both will cause unpredictable behaviour.
        location /__ledge/redis {
            internal;
            default_type text/plain;
	    	set_unescape_uri $n $arg_n;
            echo_read_request_body;

            redis2_raw_queries $n $echo_request_body;

    		redis2_connect_timeout 200ms;
    		redis2_send_timeout 200ms;
    		redis2_read_timeout 200ms;
    		redis2_pass redis;
        }
    }


## Licence

Copyright (c) 2012, James Hurst <jhurst@squiz.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
