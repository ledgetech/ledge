local config = require("lib.config")
local event = require("lib.event")

-- collapse_origin_requests
--
-- Collapse concurrent requests to the origin server into a single
-- request. The other requests wait until the first one finishes. 
-- Suits slow but cacheable origins. Probably turn this off for 
-- URIs which are deifinitely not cacheable.
config.set("collapse_origin_requests", true)

-- serve_when_stale
--
-- How 'stale' an item can be (in seconds). A stale hit will return the cached 
-- result but trigger an origin round trip in the background. 		
config.set("serve_when_stale", 3600, { 
    match_uri = { 
        { "^/about", 250 },
        { "^/contact", 350 },
    } 
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
--      events.listen("response_ready", function() 
--          ngx.log(ngx.NOTICE, "My content is ready to be sent")
--      end)

event.listen("response_sent", function() 
    ngx.log(ngx.NOTICE, "My stale config setting was  " .. ngx.ctx.config.serve_when_stale)
end)
