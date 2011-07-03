zmq = require("zmq")

local ctx = zmq.init(1)
local s = ctx:socket(zmq.PUSH)

s:connect("tcp://*:5662")

s:send("asdasdas")
--print(s:recv())

s:close()
ctx:term()