local zmq = require("zmq")
local zmq_ctx = zmq.init(1)

ngx.eof()

-- Listens on channel for messages, returns the first thing it hears.
-- Used for a simply notification "this channel has finished" etc
--[[
local sub = zmq_ctx:socket(zmq.SUB)
sub:setopt(zmq.SUBSCRIBE, 'SYN') -- Listen for SYN
sub:setopt(zmq.SUBSCRIBE, ngx.var.channel) -- Listen for correct message
sub:bind("tcp://127.0.0.1:5555")


while true do
	local msg = sub:recv()
	
	if (msg == 'SYN') then
		ngx.
	ngx.print(msg)



	sub:close()
	zmq_ctx:term()

	ngx.exit(ngx.HTTP_OK)
end
]]--
