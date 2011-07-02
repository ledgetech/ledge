local zmq = require("zmq")
local zmq_ctx = zmq.init(1)

--local pub = zmq_ctx:socket(zmq.PUB)
--pub:bind("tcp://127.0.0.1:5555")
--pub:send(' ')
-- ideally, we use SNDMORE, and send the whole response over to whoever is listening
--pub:send(uri.key)
--pub:close()

--local sub = zmq_ctx:socket(zmq.SUB)
--sub.set
ngx.eof()
