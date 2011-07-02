require("zmq")

local ctx = zmq.init(1)
local pub = ctx:socket(zmq.PUB)

pub:connect("tcp://127.0.0.1:5555")
while true do
	local msg = io.read()
	pub:send("mybighash "..msg)
end
