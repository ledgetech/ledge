local tostring = tostring
local ngx_null = ngx.null

local create_storage_connection = require("ledge").create_storage_connection


local _M = {
    _VERSION = "2.2.0",
}


-- Cleans up expired items and keeps track of memory usage.
function _M.perform(job)
    local storage, err = create_storage_connection(
        job.data.storage_driver,
        job.data.storage_driver_config
    )

    if not storage then
        return nil, "job-error", "could not connect to storage driver: "..tostring(err)
    end

    local ok, err = storage:delete(job.data.entity_id)
    storage:close()

    if ok == nil or ok == ngx_null then
        return nil, "job-error", tostring(err)
    end
end


return _M
