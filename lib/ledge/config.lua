local config = {}

-- Set a config parameter
--
-- Used by the config system to set a parameter. The vararg is an optional parameter
-- containing a table which specifies per URI or header based value filters. This allows
-- a config item to only be set on certain URIs, for example. See the config file for examples.
--
-- @param string    The config parameter
-- @param mixed     The config default value
-- @param ...       Filter table. First level is the filter type "match_uri" or "match_header".
--                  Each of these has a list of pattern => value pairs.
function config.set(param, value, ...)
    local cfg = ngx.ctx.config or {}

    cfg[param] = value
    local filters = select(1, ...)
    if filters then
        if filters.match_uri then
            for _,filter in ipairs(filters.match_uri) do
                if ngx.var.uri:find(filter[1]) ~= nil then
                    cfg[param] = filter[2]
                    break
                end
            end
        end

        if filters.match_header then
            local h = ngx.req.get_headers()
            for _,filter in ipairs(filters.match_header) do
                if h[filter[1]] ~= nil and h[filter[1]]:find(filter[2]) ~= nil then
                    cfg[param] = filter[3]
                    break
                end
            end
        end
    end

    ngx.ctx.config = cfg
end

return config
