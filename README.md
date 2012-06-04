# Ledge (Lua - Edge)

A lua module for [lua-nginx-module](https://github.com/chaoslawful/lua-nginx-module), providing edge caching functionality using [Redis](http://redis.io).

## Status

This library is considered expirmental and under active development. Functionality may change without notice.

## Description

Configurable and flexible caching behaviours for Nginx using Redis as a backend. Requires [lua-resty-rack](https://github.com/pintsized/lua-resty-rack) as well as the standard OpenResty modules.

## Synopsis
 
    content\_by\_lua '_
        local rack = require "resty.rack"
        local ledge = require "ledge.ledge"
        
        -- Ledge configuration
        local options = {
            proxy\_location = "/\_\_ledge/origin"
            redis = {
                host = "127.0.0.1",
                port = 6379,
                --socket = "unix:/tmp/redis.sock",
                --timeout = 1000,
                keepalive = {
                    max\_idle\_timeout = 0,
                    pool\_size = 100,
                }
            }
        }
        
        -- Bind to events
        ledge.bind("origin\_fetched", function(req, res)
            if req.method == "GET" then
                local ttl = 3600
                res.header["Cache-Control"] = "max-age="..ttl..", public"
                res.header["Pragma"] = nil 
                res.header["Expires"] = ngx.http\_time(ngx.time() + ttl)
            end 
        end)

        -- These config settings and plugins are on the TODO list.

        ledge.set("collapse\_origin\_requests", true)
        ledge.set("max\_stale\_age", 3600, {
            match\_uri = {
                { "/about", 60 }
            }
        })
        
        -- Install plugins (which bind to ledge events)
        -- ledge.use(ledge.plugins.esi)
        -- ledge.use(ledge.plugins.combine\_css)

        -- Install as middleware
        rack.use(ledge, options)

        -- Run the application
        rack.run()
    ';

## Author

James Hurst <jhurst@squiz.co.uk>

## Licence

Copyright (c) 2012, James Hurst <jhurst@squiz.co.uk>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
