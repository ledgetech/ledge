local require = require
local math_ceil = math.ceil
local qless = require("resty.qless")

local _M = {
    _VERSION = "2.2.0",
}

local function put_background_job( queue, klass, data, options)
    local q = qless.new({
        get_redis_client = require("ledge").create_qless_connection
    })

    -- If we've been specified a jid (i.e. a non random jid), putting this
    -- job will overwrite any existing job with the same jid.
    -- We test for a "running" state, and if so we silently drop this job.
    if options.jid then
        local existing = q.jobs:get(options.jid)

        if existing and existing.state == "running" then
            return nil, "Job with the same jid is currently running"
        end
    end

    -- Put the job
    local res, err = q.queues[queue]:put(klass, data, options)

    q:redis_close()

    if res then
        return {
            jid = res,
            klass = klass,
            options = options,
        }
    else
        return res, err
    end
end
_M.put_background_job = put_background_job


-- Calculate when to GC an entity based on its size and the minimum download
-- rate setting, plus 1 second of arbitrary latency for good measure.
local function gc_wait(entity_size, minimum_download_rate)
    local dl_rate_Bps = minimum_download_rate * 128
    return math_ceil((entity_size / dl_rate_Bps)) + 1
end
_M.gc_wait = gc_wait


return _M
