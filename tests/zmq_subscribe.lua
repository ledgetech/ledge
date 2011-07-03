zmq = require("zmq")

local ch = "ledge:d1d0ed5f3251473795548ab392181d06"

local ctx = zmq.init(1)
local s = ctx:socket(zmq.SUB)
s:setopt(zmq.SUBSCRIBE, ch)
s:bind("tcp://*:5601")

while true do
	local m = s:recv()
	if (m == ch .. ':status') then
		print("status: " .. s:recv())
	elseif (m == ch .. ':header') then
		print("header: " .. s:recv() .. ": " .. s:recv())
	elseif (m == ch .. ':body') then
		local b = s:recv()
		print("body")
	end
end
