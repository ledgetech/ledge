local zmq = require 'zmq'
local threads = require 'zmq.threads'
local context = threads.get_parent_ctx()

require 'redis'
local redis = Redis.connect('127.0.0.1', 6379)

local work = context:socket(zmq.PUSH)
assert(work:connect("inproc://stalework"))

for msg in redis:pubsub({ subscribe = 'revalidate' }) do
    if msg.kind == 'message' and msg.channel == 'revalidate' then
        work:send(msg.payload)
    end
end

work:close()
return nil
