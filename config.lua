module("config", package.seeall)

-- Configuration table
local conf = {}

conf.prefix = "/__ledge" -- Nginx internal location prefix

conf.locations = {
	origin = conf.prefix .. "/origin",
	wait_for_origin = conf.prefix .. "/wait_for_origin",
	redis = conf.prefix .. "/redis"
}

conf.max_stale_age = 60

conf.collapse_forwarding = true

return conf