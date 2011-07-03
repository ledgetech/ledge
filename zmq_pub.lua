zmq = require("zmq")
ledge = require("lib.libledge")

ngx.log(ngx.NOTICE, "SUBS: "..ngx.var.subscribers)
if (tonumber(ngx.var.subscribers) > 0) then
	--local context = zmq.init(1)
	
	ngx.log(ngx.NOTICE, "waiting for "..ngx.var.subscribers.." subscribers")

	--  Socket to publish on
	local publisher = ledge.zmq_ctx:socket(zmq.PUB)
	publisher:bind("tcp://localhost:5561")
	
	--  Socket to receive signals
	local syncservice = ledge.zmq_ctx:socket(zmq.PULL)
	syncservice:bind("tcp://*:5562")
	
	--  Get sync from subscribers.. don't do anything until they've all checked in
	local subscribers = 0
	while (subscribers < tonumber(ngx.var.subscribers)) do
	    --  - wait for synchronization request
	    local msg = syncservice:recv()

	    subscribers = subscribers + 1
	end
	
	ngx.log(ngx.NOTICE, ngx.var.subscribers.." subscribers checked in, sending..")
	publisher:send(ngx.var.channel .. " " .. ngx.var.message) -- Just send the test message now, as if it's the real d
	--publisher:send("END")

	publisher:close()
	syncservice:close()
end