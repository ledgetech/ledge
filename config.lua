-- Ledge configuration file
--
-- Nginx must be reloaded for changes to take affect. 
-- Run "lua config.lua" to check for syntax correctness.
-- TODO: Write a config check tool (test number of params to matches etc)

local esi_processor = require("plugins.esi_processor")
local preemptive_recache = require("plugins.preemptive_recache")

return {
	
	-- How 'stale' an item can be. A stale hit will return the cached 
	-- result but trigger an origin round trip in the background. 		
	max_stale_age = {
		default = 900,
		match_uri = { 
			{ "^/about", 250 },
			{ "^/contact", 360 },
		},
	},
	
	-- Collapse concurrent requests to the origin server into a single
	-- request. The other requests wait until the first one finishes. 
	-- Suits slow but cacheable origins. Probably turn this off for 
	-- URIs which are deifinitely not cacheable.
	collapse_origin_requests = {
		default = true,
		match_uri = { 
			{ "^/cart", false },
		},
	},
	
	--[[on_before_send = {
	    default = function(ledge, response)
	        --return esi_processor.process(ledge, response)
	    end
	},]]--
	
	--[[on_after_send = {
	    default = function(ledge, response)
	        --return preemptive_recache.go(ledge, response)
	    end
	}]]--

}
