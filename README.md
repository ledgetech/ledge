# Ledge (Lua - Edge)

A Lua implementation of edge proxying and caching. Relies on [nginx](http://nginx.net), the [lua-nginx-module](https://github.com/chaoslawful/lua-nginx-module) for integrating Lua coroutines into the nginx event model via nginx subrequests, as well as [Redis](http://redis.io) as an upstream server to act as a cache backend.

### Authors

* James Hurst <james@pintsized.co.uk>

## Status

Experimental prototype. Not at all ready for production, but ideas welcome.

### Working

* Proxying to upstream server
* Cache storage in Redis
* Serving stale content
* Collapse forwarding

### TODO

* Determine cache policy from headers
* Prove stability / bench
* Start adding modularised cool stuff
	* ESI
	* Auth patterns / sessions?
	* ...

## Installation

This is not exhaustive.. you're on the bleeding (l)edge here. Getting all the tools to work took me longer than writing the code.  

### ngx_openresty

Follow the instructions here: http://github.com/agentzh/ngx_openresty

Requires the following modules (which are built by default)

* ngx_lua
* echo-nginx-module
* redis2-nginx-module

And for better performance, compile --with-luajit

You'll also need the redis parser: https://github.com/agentzh/lua-redis-parser

### Redis

Download and install from http://redis.io/download

### nginx configuration

#### Lua package path

This is configured at the 'http' level of the nginx conf, not per server, and must be set to where you install ledge. e.g.

	# Ledge, followed by default (;;)
	lua_package_path '/home/me/ledge/?.lua;;';

#### Redis upstream

Also at the http level:

	# keepalive connection pool to a single redis running on localhost
	upstream redis {   
		server localhost:6379;
		
    	# a pool with at most 1024 connections
    	# and do not distinguish the servers:
		keepalive 1024 single;
	}
	
#### Example server configuration

	server {
	    listen       80;
	    server_name  myserver;
	    #lua_code_cache off;
		
	    #charset koi8-r;
	    #access_log  logs/host.access.log  main;
		
		# By default, we hit the lua code
		location / {
	        set $full_uri $scheme://$host$request_uri;
			
			# Wherever you install ledge
			content_by_lua_file '/home/me/ledge/main.lua';
		}
		
		# Proxy to origin server
		location /__ledge/origin {
			internal;
			rewrite ^/__ledge/origin(.*)$ $1 break;
			proxy_set_header X-Real-IP  $remote_addr;
			proxy_set_header X-Forwarded-For $remote_addr;
			proxy_set_header Host $host;
			
			proxy_pass http://127.0.0.1:8081;
		}
		
		# For SUBSCRIBING to messages from Redis (collapse forwarding)
		location /__ledge/wait_for_origin {
          	internal;
          	set_unescape_uri $channel $arg_channel;
        	redis2_raw_queries 2 "SUBSCRIBE $channel\r\n"
			
       		redis2_connect_timeout 200ms;
       		redis2_send_timeout 200ms;
           	redis2_read_timeout 60s;
      		redis2_pass redis_subscribe;
		}
		
	    # Redis
	    # Accepts raw queries as POST body.
		# Expects the arg 'n' for the query count
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

