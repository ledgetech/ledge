zmq = require("zmq")

local ctx = zmq.init(1)
local s = ctx:socket(zmq.PULL)

s:bind("tcp://*:5662")

while true do
    print(string.format("Received query: '%s'", s:recv()))
   -- s:send("OK")
end
