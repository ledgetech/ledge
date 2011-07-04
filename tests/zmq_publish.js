zmq = require("zmq")

local ch = "ledge:d1d0ed5f3251473795548ab392181d06"

local ctx = zmq.init(1)
local s = ctx:socket(zmq.PUB)
s:bind("tcp://*:5601")

while true do
	local msg = io.read()
	s:send(ch..' '..msg)
end