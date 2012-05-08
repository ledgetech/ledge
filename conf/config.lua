local config = require("ledge.config")
local event = require("ledge.event")
local ledge = require("ledge.ledge")

-- collapse_origin_requests
--
-- Collapse concurrent requests to the origin server into a single
-- request. The other requests wait until the first one finishes. 
-- Suits slow but cacheable origins. Probably turn this off for 
-- URIs which are deifinitely not cacheable.
config.set("collapse_origin_requests", false)

-- serve_when_stale
--
-- How 'stale' an item can be (in seconds). A stale hit will return the cached 
-- result but trigger an origin round trip in the background. 		
config.set("serve_when_stale", 300, { 
    match_uri = { 
        { "^/esi%-fragments/time", 60 },
    },
})

-- You can define event handlers too. Predefined events are:
--
--  * config_loaded     (before anything happens)
--  * cache_accessed    (cache state established)
--  * origin_required   (we're going to the origin)
--  * origin_fetched    (successfully fetched from the origin)
--  * response_ready    (response is ready to be sent)
--  * response_sent     (response has been sent to the browser)
--  * finished          (we're about to exit)
--
-- Example:
--
--      event.listen("response_ready", function() 
--          ngx.log(ngx.NOTICE, "My content is ready to be sent")
--      end)

-- Remove Set-Cookie for cacheable responses
--[[
event.listen("response_ready", function()
    local response = ngx.ctx.response
    if response.state >= ledge.states.WARM and response.header['Set-Cookie'] then
        response.header['Set-Cookie'] = nil
    end
end)
--]]

-- Completely disregard no-cache
event.listen("origin_fetched", function()
    if ngx.var.host == 'reboot.squiz.net' and ngx.var.request_method == "GET" then
        local ttl = 3600
        ngx.ctx.response.header['Cache-Control'] = "max-age="..ttl..", public"
        ngx.ctx.response.header['Pragma'] = nil
        ngx.ctx.response.header['Expires'] = ngx.http_time(ngx.time() + ttl)
    end
end)

-- A basic ESI parser
--[[event.listen("response_ready", function()
    local response = ngx.ctx.response
    if not response.body then return end

    -- We can't do ngx.location.capture within a Lua callback, so we must fetch
    -- in advance, and then swap afterwards.
    local tags = {response.body:match('(<esi:include.-/>)')}
    local uris = {}

    for i,tag in ipairs(tags) do
        local _, _, src = tag:find('src="(.-)"')

        local fragment = ngx.location.capture(src, {
            method = ngx.HTTP_GET,
        })

        if fragment.status == ngx.HTTP_OK then
            uris[src] = fragment
        else 
            ngx.log(ngx.NOTICE, "No response: " ..fragment.status)
        end
    end
    
    -- Now actually do the replacement.
    response.body = response.body:gsub('(<esi:include.-/>)', function(tag)
        local _, _, src = tag:find('src="(.-)"')
        return uris[src].body
    end)
    ngx.ctx.response = response
end)
]]--
