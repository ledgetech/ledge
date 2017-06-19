local ledge = require("ledge")
local h_util = require("ledge.header_util") -- TODO pull in functions needed?
local esi = require("ledge.esi")
local range = require("ledge.range")

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_PARTIAL_CONTENT = ngx.PARTIAL_CONTENT
local ngx_null = ngx.null
local ngx_PARTIAL_CONTENT = 206
local ngx_RANGE_NOT_SATISFIABLE = 416
local ngx_HTTP_NOT_MODIFIED = 304

local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_headers = ngx.req.get_headers

local ngx_re_find = ngx.re.find
local ngx_re_match = ngx.re.match

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
local purge_in_background = require("ledge.purge").purge_in_background
local create_purge_response = require("ledge.purge").create_purge_response

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable



local _M = {
    _VERSION = "1.28.3",
}


-- Decision states.
-- Represented as functions which should simply make a decision, and return
-- calling state_machine:e(ev) with the event that has occurred. Place any
-- further logic in actions triggered by the transition table.
return {
    checking_method = function(sm, handler)
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

    considering_wildcard_purge = function(sm, handler)
        local key_chain = handler:cache_key_chain()
        if ngx_re_find(key_chain.root, "\\*", "soj") then
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

    accept_cache = function(sm, handler)
        return sm:e "cache_accepted"
    end,

    checking_request = function(sm, handler)
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
            local accepts_gzip = h_util.header_has_directive(accept_encoding, "gzip")

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
            local processor = esi.choose_esi_processor(res)
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
                handler.esi_processor = esi.choose_esi_processor(res)
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

        if h_util.header_has_directive(
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
        local redis = handler.redis
        local key_chain = handler:cache_key_chain()
        local lock_key = key_chain.fetching_lock

        local timeout = tonumber(handler.config.collapsed_forwarding_window)
        if not timeout then
            ngx_log(ngx_ERR, "collapsed_forwarding_window must be a number")
            return sm:e "collapsed_forwarding_failed"
        end

        -- Watch the lock key before we attempt to lock. If we fail to lock, we need to subscribe
        -- for updates, but there's a chance we might miss the message.
        -- This "watch" allows us to abort the "subscribe" transaction if we've missed
        -- the opportunity.
        --
        -- We must unwatch later for paths without transactions, else subsequent transactions
        -- on this connection could fail.
        redis:watch(lock_key)

        local res, err = handler:acquire_lock(lock_key, timeout)

        if res == nil then -- Lua script failed
            redis:unwatch()
            ngx_log(ngx_ERR, err)
            return sm:e "collapsed_forwarding_failed"
        elseif res then -- We have the lock
            redis:unwatch()
            return sm:e "obtained_collapsed_forwarding_lock"
        else -- Lock is busy
            redis:multi()
            redis:subscribe(key_chain.root)
            if redis:exec() ~= ngx_null then -- We subscribed before the lock was freed
                return sm:e "subscribed_to_collapsed_forwarding_channel"
            else -- Lock was freed before we subscribed
                return sm:e "collapsed_forwarding_channel_closed"
            end
        end
    end,

    publishing_collapse_success = function(sm, handler)
        local redis = handler.redis
        local key_chain = handler:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_response_ready")
        return sm:e "published"
    end,

    publishing_collapse_failure = function(sm, handler)
        local redis = handler.redis
        local key_chain = handler:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_forwarding_failed")
        return sm:e "published"
    end,

    publishing_collapse_upstream_error = function(sm, handler)
        local redis = handler.redis
        local key_chain = handler:cache_key_chain()
        redis:del(key_chain.fetching_lock) -- Clear the lock
        redis:publish(key_chain.root, "collapsed_forwarding_upstream_error")
        return sm:e "published"
    end,

    fetching_as_surrogate = function(sm, handler)
        return sm:e "can_fetch"
    end,

    waiting_on_collapsed_forwarding_channel = function(sm, handler)
        local redis = handler.redis

        -- Extend the timeout to the size of the window
        redis:set_timeout(handler.config.collapsed_forwarding_window)
        local res, err = redis:read_reply() -- block until we hear something or timeout
        if not res then
            return sm:e "http_gateway_timeout"
        else
            -- TODO this config is now in the singleton
            redis:set_timeout(60) --handler.config.redis_read_timeout)
            redis:unsubscribe()

            -- This is overly explicit for the sake of state machine introspection. That is
            -- we never call sm:e() without a literal event string.
            if res[3] == "collapsed_response_ready" then
                return sm:e "collapsed_response_ready"
            elseif res[3] == "collapsed_forwarding_upstream_error" then
                return sm:e "collapsed_forwarding_upstream_error"
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
                -- TODO: move this to a range util
                local m, err = ngx_re_match(
                    content_range,
                    [[bytes\s+(?:\d+|\*)-(?:\d+|\*)/(\d+)]],
                    "oj"
                )

                if m then
                    local size = tonumber(m[1])
                    local max_size = handler.storage:get_max_size()
                    if type(max_size) == "number" and max_size > size then
                        return sm:e "can_fetch_in_background"
                    end
                end
            end

            return sm:e "background_fetch_skipped"
        end
    end,

    purging = function(sm, handler)
        local mode = purge_mode()
        local ok, message, job = purge(handler, mode)
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

    considering_local_revalidation = function(sm, handler)
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

    preparing_response = function(sm, handler)
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

    exiting = function(sm, handler)
        ngx.exit(ngx.status)
    end,

    cancelling_abort_request = function(sm, handler)
        return true
    end,
}
