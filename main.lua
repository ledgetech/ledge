local ledge = require("ledge")

-- Read in the config file to determine run level options for this request
ledge.process_config()

-- keys is a table of cache keys indentifying this request in redis
local keys = ledge.create_keys(ngx.var.full_uri)

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
    ngx.log(ngx.NOTICE, "on_after_send event handler is not a function")
end
