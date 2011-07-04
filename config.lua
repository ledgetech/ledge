module("config", package.seeall)

-- Ledge configuration file
--
-- Nginx must be reloaded for changes to take affect. 
-- Run "lua config.lua" to check for syntax correctness.
-- TODO: Write a config check tool (test number of params to matches etc)
return {
	
	-- How 'stale' an item can be. A stale hit will return the cached 
	-- result but trigger an origin round trip in the background. 		
	max_stale_age = {
		default = 900,
		match_uri = { 
			{ "^/about", 0 },
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
	
	-- Whether to attempt ESI processing.
	process_esi = {
		default = false,
		match_header = {
			{ "X-ESI", "Contains Fragments", true },
		},
	},
	
}
