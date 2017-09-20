local ledge = require("ledge")
local esi = require("ledge.esi")
local range = require("ledge.range")

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_null = ngx.null

local ngx_PARTIAL_CONTENT = 206

local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_headers = ngx.req.get_headers

local str_find = string.find
local str_lower = string.lower

local header_has_directive = require("ledge.header_util").header_has_directive

local can_revalidate_locally =
    require("ledge.validation").can_revalidate_locally
local must_revalidate = require("ledge.validation").must_revalidate
local is_valid_locally = require("ledge.validation").is_valid_locally

local can_serve_stale = require("ledge.stale").can_serve_stale
local can_serve_stale_if_error = require("ledge.stale").can_serve_stale_if_error
local can_serve_stale_while_revalidate =
    require("ledge.stale").can_serve_stale_while_revalidate

local req_accepts_cache = require("ledge.request").accepts_cache
local purge_mode = require("ledge.request").purge_mode

local purge = require("ledge.purge").purge
local purge_api = require("ledge.purge").purge_api
local purge_in_background = require("ledge.purge").purge_in_background
local create_purge_response = require("ledge.purge").create_purge_response

local acquire_lock = require("ledge.collapse").acquire_lock

local parse_content_range = require("ledge.range").parse_content_range

local vary_spec_compare = require("ledge.cache_key").vary_spec_compare


local _M = { -- luacheck: no unused
    _VERSION = "2.0.0",
}


-- Decision states.
-- Represented as functions which should simply make a decision, and return
-- calling state_machine:e(ev) with the event that has occurred. Place any
-- further logic in actions triggered by the transition table.
return {
    checking_method = function(sm)
        local method = ngx_req_get_method()
        if method == "PURGE" then
            return sm:e "purge_requested"
        elseif method ~= "GET" and method ~= "HEAD" then
            -- Only GET/HEAD are cacheable
            return sm:e "cache_not_accepted"
        else
            return sm:e "cacheable_method"
        end
    end,

    considering_purge_api = function(sm)
        local ct = ngx_req_get_headers()["Content-Type"]
        if ct and str_lower(ct) == "application/json" then
            return sm:e "purge_api_requested"
        else
            return sm:e "purge_requested"
        end
    end,

    considering_wildcard_purge = function(sm, handler)
        local key_chain = handler:cache_key_chain()
        if str_find(key_chain.root, "*", 1, true) then
            return sm:e "wildcard_purge_requested"
        else
            return sm:e "purge_requested"
        end
    end,

    checking_origin_mode = function(sm, handler)
        -- Ignore the client requirements if we're not in "NORMAL" mode.
        if handler.config.origin_mode < ledge.ORIGIN_MODE_NORMAL then
            return sm:e "forced_cache"
        else
            return sm:e "cacheable_method"
        end
    end,

    accept_cache = function(sm)
        return sm:e "cache_accepted"
    end,

    checking_request = function(sm)
        if req_accepts_cache() then
            return sm:e "cache_accepted"
        else
            return sm:e "cache_not_accepted"
        end
    end,

    checking_cache = function(sm, handler)
        local res = handler.response

        if not next(res) then
            return sm:e "cache_missing"
        elseif res:has_expired() then
            return sm:e "cache_expired"
        else
            return sm:e "cache_valid"
        end
    end,

    considering_gzip_inflate = function(sm, handler)
        local res = handler.response
        local accept_encoding = ngx_req_get_headers()["Accept-Encoding"] or ""

        -- If the response is gzip encoded and the client doesn't support it, then inflate
        if res.header["Content-Encoding"] == "gzip" then
            local accepts_gzip = header_has_directive(accept_encoding, "gzip")

            if handler.esi_scan_enabled or
                (handler.config.gunzip_enabled and accepts_gzip == false) then
                return sm:e "gzip_inflate_enabled"
            end
        end

        return sm:e "gzip_inflate_disabled"
    end,

    considering_esi_scan = function(sm, handler)
        if handler.config.esi_enabled == true then
            local res = handler.response
            if not res.has_body then
                return sm:e "esi_scan_disabled"
            end

            -- Choose an ESI processor from the Surrogate-Control header
            -- (Currently there is only the ESI/1.0 processor)
            local processor = esi.choose_esi_processor(handler)
            if processor then
                if esi.is_allowed_content_type(res, handler.config.esi_content_types) then
                    -- Store parser for processing
                    -- TODO: Strictly this should be installed by the state machine
                    handler.esi_processor = processor
                    return sm:e "esi_scan_enabled"
                end
            end
        end

        return sm:e "esi_scan_disabled"
    end,

    -- We decide to process if:
    --  - We know the response has_esi (fast path)
    --  - We already decided to scan for esi (slow path)
    --  - We aren't delegating responsibility downstream, which would occur when both:
    --      - Surrogate-Capability is set with a matching parser type and version.
    --      - Delegation is enabled in configuration.
    --
    --  So essentially, if we think we may need to process, then we do. We don't want to
    --  accidentally send ESI instructions to a client, so we only delegate if we're sure.
    considering_esi_process = function(sm, handler)
        local res = handler.response

        -- If we know there's no esi or it hasn't been scanned, don't process
        if not res.has_esi and res.esi_scanned == false then
            return sm:e "esi_process_disabled"
        end

        if not next(handler.esi_processor) then
            -- On the fast path with ESI already detected, the processor wont have been loaded
            -- yet, so we must do that now
            -- TODO: Perhaps the state machine can load the processor to avoid this weird check
            if res.has_esi then
                local p = esi.choose_esi_processor(handler)
                if not p then
                    -- This shouldn't happen
                    -- if res.has_esi is set then a processor should be selectedable
                    return sm:e "esi_process_not_required"
                else
                    handler.esi_processor = p
                end
            else
                -- We know there's nothing to do
                return sm:e "esi_process_not_required"
            end
        end

        if esi.can_delegate_to_surrogate(
            handler.config.esi_allow_surrogate_delegation,
            handler.esi_processor.token
        ) then
            -- Disabled due to surrogate delegation
            return sm:e "esi_process_disabled"
        else
            return sm:e "esi_process_enabled"
        end
    end,

    checking_range_request = function(sm, handler)
        local res = handler.response

        -- TODO this should just check, not install range?
        local range = range.new()
        local res, partial_response = range:handle_range_request(res)

        handler.range = range
        handler.response = res

        if partial_response then
            return sm:e "range_accepted"
        elseif partial_response == false then
            return sm:e "range_not_accepted"
        else
            return sm:e "range_not_requested"
        end
    end,

    checking_can_fetch = function(sm, handler)
        if handler.config.origin_mode == ledge.ORIGIN_MODE_BYPASS then
           return sm:e "http_service_unavailable"
        end

        if header_has_directive(
            ngx_req_get_headers()["Cache-Control"], "only-if-cached"
        ) then
            return sm:e "http_gateway_timeout"
        end

        if handler.config.enable_collapsed_forwarding then
            return sm:e "can_fetch_but_try_collapse"
        end

        return sm:e "can_fetch"
    end,

    requesting_collapse_lock = function(sm, handler)
        local timeout = tonumber(handler.config.collapsed_forwarding_window)
        if not timeout then
            ngx_log(ngx_ERR, "collapsed_forwarding_window must be a number")
            return sm:e "collapsed_forwarding_failed"
        end

        local redis = handler.redis
        local key_chain = handler:cache_key_chain()
        local lock_key = key_chain.fetching_lock

        local res, err = acquire_lock(redis, lock_key, timeout)

        if res == nil then -- Lua script failed
            if err then ngx_log(ngx_ERR, err) end
            return sm:e "collapsed_forwarding_failed"
        elseif res then -- We have the lock
            return sm:e "obtained_collapsed_forwarding_lock"
        else
            -- We didn't get the lock, try to collapse
            -- Create a new Redis connection and put it into subscribe mode
            -- Then check if the lock still exists as it may have been freed
            -- in the time between attempting to acquire and subscribing.
            -- In which case we have missed the publish event

            local redis_subscriber = ledge.create_redis_connection()
            local ok, err = redis_subscriber:subscribe(lock_key)
            if not ok or ok == ngx_null then
                -- Failed to enter subscribe mode
                if err then ngx_log(ngx_ERR, err) end
                return sm:e "collapsed_forwarding_failed"
            end

            local ok, err = redis:exists(lock_key)
            if ok == 1 then
                -- We subscribed before the lock was freed
                handler.redis_subscriber = redis_subscriber
                return sm:e "subscribed_to_collapsed_forwarding_channel"
            elseif ok == 0 then
                -- Lock was freed before we subscribed
                return sm:e "collapsed_forwarding_channel_closed"
            else
                -- Error checking lock still exists
                if err then ngx_log(ngx_ERR, err) end
                return sm:e "collapsed_forwarding_failed"
            end
        end
    end,

    publishing_collapse_success = function(sm, handler)
        local redis = handler.redis
        local key = handler._publish_key
        redis:del(key) -- Clear the lock
        redis:publish(key, "collapsed_response_ready")

        return sm:e "published"
    end,

    publishing_collapse_failure = function(sm, handler)
        local redis = handler.redis
        local key = handler._publish_key
        redis:del(key) -- Clear the lock
        redis:publish(key, "collapsed_forwarding_failed")

        return sm:e "published"
    end,

    publishing_collapse_upstream_error = function(sm, handler)
        local redis = handler.redis
        local key = handler._publish_key
        redis:del(key) -- Clear the lock
        redis:publish(key, "collapsed_forwarding_upstream_error")

        return sm:e "published"
    end,

    publishing_collapse_vary_modified = function(sm, handler)
        local redis = handler.redis
        local key = handler._publish_key
        redis:del(key) -- Clear the lock
        redis:publish(key, "collapsed_forwarding_vary_modified")

        return sm:e "published"
    end,

    fetching_as_surrogate = function(sm, handler)
        -- stash these because we might change the key
        -- depending on vary response
        local key_chain = handler:cache_key_chain()
        handler._publish_key = key_chain.fetching_lock

        return sm:e "can_fetch"
    end,

    considering_vary = function(sm, handler)
        local new_spec = handler.response:process_vary()
        local key_chain = handler:cache_key_chain()

        if vary_spec_compare(new_spec, key_chain.vary_spec) then
            handler:set_vary_spec(new_spec)
            return sm:e "vary_modified"

        else
            return sm:e "vary_unmodified"

        end
    end,

    waiting_on_collapsed_forwarding_channel = function(sm, handler)
        local redis = handler.redis_subscriber

        -- Extend the timeout to the size of the window
        redis:set_timeout(handler.config.collapsed_forwarding_window)
        local res, _ = redis:read_reply() -- block until we hear something or timeout
        if not res or res == ngx_null then
            return sm:e "collapsed_forwarding_failed"
        else
            -- TODO this config is now in the singleton
            redis:set_timeout(60) --handler.config.redis_read_timeout)
            redis:unsubscribe()
            ledge.close_redis_connection(redis)

            -- This is overly explicit for the sake of state machine introspection. That is
            -- we never call sm:e() without a literal event string.
            if res[3] == "collapsed_response_ready" then
                return sm:e "collapsed_response_ready"
            elseif res[3] == "collapsed_forwarding_upstream_error" then
                return sm:e "collapsed_forwarding_upstream_error"
            elseif res[3] == "collapsed_forwarding_vary_modified" then
                return sm:e "collapsed_forwarding_vary_modified"
            else
                return sm:e "collapsed_forwarding_failed"
            end
        end
    end,

    fetching = function(sm, handler)
        local res = handler.response

        if res.status >= 500 then
            return sm:e "upstream_error"
        elseif res.status == ngx.HTTP_NOT_MODIFIED then
            return sm:e "response_ready"
        elseif res.status == ngx_PARTIAL_CONTENT then
            return sm:e "partial_response_fetched"
        else
            return sm:e "response_fetched"
        end
    end,

    considering_background_fetch = function(sm, handler)
        local res = handler.response
        if res.status ~= ngx_PARTIAL_CONTENT then
            -- Shouldn't happen, but just in case
            return sm:e "background_fetch_skipped"
        else
            local content_range = res.header["Content-Range"]
            if content_range then
                local _, _, size = parse_content_range(content_range)

                if size then
                    local max_size = handler.storage:get_max_size()
                    if type(max_size) == "number" and max_size > size then
                        return sm:e "can_fetch_in_background"
                    end
                end
            end

            return sm:e "background_fetch_skipped"
        end
    end,

    purging_via_api = function(sm, handler)
        local ok = purge_api(handler)
        if ok then
            return sm:e "purge_api_completed"
        else
            return sm:e "purge_api_failed"
        end
    end,

    purging = function(sm, handler)
        local mode = purge_mode()
        local ok, message, job = purge(handler, mode, handler:cache_key_chain().repset)
        local json = create_purge_response(mode, message, job)
        handler.response:set_body(json)

        if ok then
            return sm:e "purged"
        else
            return sm:e "nothing_to_purge"
        end
    end,

    wildcard_purging = function(sm, handler)
        purge_in_background(handler, purge_mode())
        return sm:e "wildcard_purge_scheduled"
    end,

    considering_stale_error = function(sm, handler)
        local res = handler.response
        if can_serve_stale_if_error(res) then
            return sm:e "can_serve_disconnected"
        else
            return sm:e "can_serve_upstream_error"
        end
    end,

    serving_upstream_error = function(sm, handler)
        handler:serve()
        return sm:e "served"
    end,

    considering_revalidation = function(sm, handler)
        if must_revalidate(handler.response) then
            return sm:e "must_revalidate"
        elseif can_revalidate_locally() then
            return sm:e "can_revalidate_locally"
        else
            return sm:e "no_validator_present"
        end
    end,

    considering_local_revalidation = function(sm)
        if can_revalidate_locally() then
            return sm:e "can_revalidate_locally"
        else
            return sm:e "no_validator_present"
        end
    end,

    revalidating_locally = function(sm, handler)
        if is_valid_locally(handler.response) then
            return sm:e "not_modified"
        else
            return sm:e "modified"
        end
    end,

    checking_can_serve_stale = function(sm, handler)
        local res = handler.response
        if handler.config.origin_mode < ledge.ORIGIN_MODE_NORMAL then
            return sm:e "can_serve_stale"
        elseif can_serve_stale_while_revalidate(res) then
            return sm:e "can_serve_stale_while_revalidate"
        elseif can_serve_stale(res) then
            return sm:e "can_serve_stale"
        else
            return sm:e "cache_expired"
        end
    end,

    updating_cache = function(sm, handler)
        local res = handler.response
        if res.has_body then
            if res:is_cacheable() then
                return sm:e "response_cacheable"
            else
                return sm:e "response_not_cacheable"
            end
        else
            return sm:e "response_body_missing"
        end
    end,

    preparing_response = function(sm)
        return sm:e "response_ready"
    end,

    serving = function(sm, handler)
        handler:serve()
        return sm:e "served"
    end,

    serving_stale = function(sm, handler)
        handler:serve()
        return sm:e "served"
    end,

    exiting = function()
        ngx.exit(ngx.status)
    end,

    cancelling_abort_request = function()
        return true
    end,
}
