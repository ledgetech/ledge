local ledge = require("ledge")
ledge.process_config()

-- A table for the uri and keys
local uri = {}
uri.uri 		= ngx.var.full_uri
uri.key 		= 'ledge:'..ngx.md5(ngx.var.full_uri) -- Hash, with .status, and .body
uri.header_key	= uri.key..':header'	-- Hash, with header names and values
uri.meta_key	= uri.key..':meta'		-- Meta, hash with .cacheable = true|false. Persistent.
uri.fetch_key	= uri.key..':fetch'		-- Temp key during an origin request.

local res = ledge.prepare(uri)

if (res.state == ledge.states.HOT) then
	ledge.send(res)
elseif (res.state == ledge.states.WARM) then
	ledge.send(res)
	ledge.fetch(uri, res)
elseif (res.state < ledge.states.WARM) then
	res = ledge.fetch(uri, res)
	ledge.send(res)
end

if type(ledge.config.on_after_send) == 'function' then
    response = ledge.config.on_after_send(ledge, res)
else
    ngx.log(ngx.NOTICE, "on_after_send event handler is not a function")
end
