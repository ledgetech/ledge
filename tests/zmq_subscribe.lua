require("zmq")

local ctx = zmq.init(1)

local sub = ctx:socket(zmq.SUB)
sub:setopt(zmq.SUBSCRIBE, "mybighash")
sub:bind("tcp://127.0.0.1:5555")

term = false
while true do
	if term then
		sub:close()
		ctx:term()
		break
	end
	
    local msg = sub:recv()
	print(msg)
	
	for m in string.gmatch(msg, "%a+") do
		if m == 'SAVED' then
			term = true
		end
	end
end
