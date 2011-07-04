module("config", package.seeall)

return {
	
	-- How 'stale' an item can be. 
	-- A stale hit will return the cached result but 
	-- trigger an origin round trip in the background. 
	max_stale_age = 900,
	
	-- Collapse concurrent COLD hits into a single origin
	-- request. The other requests wait until the first one 
	-- finishes. 
	collapse_forwarding = true,
}
