require("zmq")

local ctx = zmq.init(1)

local sub = ctx:socket(zmq.SUB)
sub:setopt(zmq.SUBSCRIBE, "")
sub:connect("tcp://127.0.0.1:5561")

while true do
    local msg = sub:recv()
	print(msg)
end
