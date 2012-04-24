local id = ...

local zmq = require 'zmq'
local threads = require 'zmq.threads'
local context = threads.get_parent_ctx()

-- PULL jobs from the primers socket
local jobs = context:socket(zmq.PULL)
assert(jobs:connect("inproc://primers"))

function log(msg)
    io.stdout:write(os.date('%c', os.time()) .. ' ' .. msg .. "\n")
    io.stdout:flush()
end

local http = require 'socket.http'
local url = require 'socket.url'

while true do
    local msg = jobs:recv()
    log("#"..id.." Priming " .. msg)

    -- Change the host to localhost.. we'll manually add the Host header.
    local parsed_url = url.parse(msg)
    local origin_host = parsed_url.host
    parsed_url.host = '127.0.0.1'

    --  Do some 'work'
    local s, c, h = http.request({
        url = url.build(parsed_url),
        headers = { 
            ['Cache-Control'] = 'no-cache',
            ['Host'] = origin_host
        },
    })

    log("#"..id.." Done ("..c..")")

end
jobs:close()
return nil
