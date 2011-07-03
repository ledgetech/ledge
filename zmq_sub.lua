zmq = require("zmq")
--require("zhelpers")
ledge = require("lib.libledge")


--local context = zmq.init(1)

--  First, connect our subscriber socket
local subscriber = ledge.zmq_ctx:socket(zmq.SUB)

subscriber:setopt(zmq.SUBSCRIBE, "")
subscriber:connect("tcp://*:5561")


ngx.log(ngx.NOTICE, "subscribed")

--  0MQ is so fast, we need to wait a while…
--s_sleep (1000) 
--os.execute('sleep 3')

ngx.log(ngx.NOTICE, "going to sync")

--  Second, synchronize with publisher
local syncclient = ledge.zmq_ctx:socket(zmq.PUSH)
syncclient:connect("tcp://localhost:5562")

--  - send a synchronization request
syncclient:send("")
ngx.log(ngx.NOTICE, "waiting messages")

local msg = subscriber:recv()
ngx.log(ngx.NOTICE, "got message")

ngx.print(msg)
--end

subscriber:close()
syncclient:close()
--context:term()
