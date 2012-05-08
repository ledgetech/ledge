-- Event registration is handled in the config file. Nothing is prescribed, config 
-- code is free to define and listen to any event. The predefined event are:
--
--  * config_loaded     (before anything happens)
--  * cache_accessed    (cache state established)
--  * origin_required   (we're going to the origin)
--  * origin_fetched    (successfully fetched from the origin)
--  * response_ready    (response is ready to be sent)
--  * response_sent     (response has been sent to the browser)
--  * finished          (we're about to exit)
local event = {}


-- Attach handler to an event
-- 
-- @param string    The event identifier
-- @param function  The event handler
-- @return void
function event.listen(event, handler)
    local e = ngx.ctx.event or {}
    if not e[event] then e[event] = {} end
    table.insert(e[event], handler)
    ngx.ctx.event = e
end


-- Broadcast an event
--
-- @param string    The event identifier
-- @return void
function event.emit(event)
    local e = ngx.ctx.event or {}
    for _,handler in ipairs(e[event] or {}) do
        if type(handler) == 'function' then
            handler()
        end
    end
end

return event
