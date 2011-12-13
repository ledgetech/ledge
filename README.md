# Ledge (Lua - Edge)

A attempt at edge proxying and caching logic in Lua. Relies on [nginx](http://nginx.net), the [lua-nginx-module](https://github.com/chaoslawful/lua-nginx-module) for integrating Lua coroutines into the nginx event model via nginx subrequests, as well as [Redis](http://redis.io) as an upstream server to act as a cache backend.

### Authors

* James Hurst <jhurst@squiz.co.uk>

## Status

Experimental prototype. Not at all ready for production, currently still proving out the technology. But ideas welcome.

## Installation

This is not exhaustive.. you're on the bleeding (l)edge here.

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
        server_name  jhurst-dev01.squiz.co.uk; 
        access_log  logs/access.log  main;
		
    	# By default, we hit the Squiz Edge Lua code
    	location / {
			lua_need_request_body on;
            # Ledge needs $scheme, but this is empty unless evaluated in the config.
            # So for convenience, we define $full_uri for use in Lua.
			set $full_uri $scheme://$host$uri$is_args$args;
            # Nginx locations for Ledge to do I/O. 
            set $loc_redis '/__ledge/redis';
            set $loc_origin '/__ledge/origin';
            set $loc_wait_for_origin '/__ledge/wait_for_origin';

            # Auth stage
            # access_by_lua_file '/home/jhurst/prj/squiz_edge/ledge/auth.lua';
            # Content stage
            content_by_lua_file '/home/jhurst/prj/squiz_edge/ledge/content.lua';
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

