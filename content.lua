local ledge = require("lib.ledge")

-- Read in the config file to determine run level options for this request
ledge.process_config()

-- keys is a table of cache keys indentifying this request in redis
local full_uri = ngx.var.scheme..'://'..ngx.var.host
if (ngx.var.request_uri ~= '/') then 
    -- We don't want to accidentally add a trailing slash, so only add the path
    -- if there's something there.
    full_uri = full_uri .. ngx.var.request_uri
end
--ngx.log(ngx.NOTICE, ngx.var.args)
--if (ngx.var.args ~= "") then
--    full_uri = full_uri..'?'..ngx.var.args
--end
local keys = ledge.create_keys(full_uri)

-- Prepare fetches from cache, so we're either primed with a full response
-- to send, or cold with an empty response which must be fetched.
local response = ledge.prepare(keys)

-- Send and/or fetch, depending on the state
if (response.state == ledge.states.HOT) then
	ledge.send(response)
elseif (response.state == ledge.states.WARM) then
	ledge.send(response)
	ledge.fetch(keys, response)
elseif (response.state < ledge.states.WARM) then
	response = ledge.fetch(keys, response)
	ledge.send(response)
end

if type(ledge.config.on_after_send) == 'function' then
    response = ledge.config.on_after_send(ledge, response)
else
    --ngx.log(ngx.NOTICE, "on_after_send event handler is not a function")
end
