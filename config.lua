module("config", package.seeall)

-- Configuration table
local conf = {}
conf.prefix = "/__ledge" -- Nginx internal location prefix
conf.proxy = {
    loc = conf.prefix .. "/proxy" -- proxy location
} 
conf.redis = {
    loc = conf.prefix .. "/redis",
    max_stale_age = 900, -- How stale a valid cache entry can be
}

return conf