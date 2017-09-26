local _M = {
    _VERSION = "2.0.3",
}


-- Event transition table.
--
-- Use "begin" to transition based on an event. Filter transitions by current
-- state "when", and/or any previous state "after", and/or a previously fired
-- event "in_case", and run actions using "but_first". Transitions are processed
-- in the order found, so place more specific entries for a given event before
-- more generic ones.
return {
    -- Initial transition (entry point). Connect to redis.
    init = {
        { begin = "checking_method", but_first = "filter_esi_args" },
    },

    cacheable_method = {
        { when = "checking_origin_mode", begin = "checking_request" },
        { begin = "checking_origin_mode" },
    },

    -- PURGE method detected.
    purge_requested = {
        {
            when = "considering_wildcard_purge",
            begin = "purging",
            but_first = "set_json_response"
        },
        { begin = "considering_wildcard_purge" },
    },

    wildcard_purge_requested = {
        { begin = "wildcard_purging", but_first = "set_json_response" },
    },

    -- Succesfully purged (expired) a cache entry. Exit 200 OK.
    purged = {
        { begin = "serving", but_first = "set_http_ok" },
    },

    wildcard_purge_scheduled = {
        { begin = "serving", but_first = "set_http_ok" },
    },

    -- URI to purge was not found. Exit 404 Not Found.
    nothing_to_purge = {
        { begin = "serving", but_first = "set_http_not_found" },
    },

    -- The request accepts cache. If we've already validated locally, we can
    -- think about serving. Otherwise we need to check the cache situtation.
    cache_accepted = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
        { begin = "checking_cache" },
    },

    forced_cache = {
        { begin = "accept_cache" },
    },

    -- This request doesn't accept cache, so we need to see about fetching
    cache_not_accepted = {
        { begin = "checking_can_fetch" },
    },

    -- We don't know anything about this URI, so we've got to see about fetching
    cache_missing = {
        { begin = "checking_can_fetch" },
    },

    -- This URI was cacheable last time, but has expired. So see about serving
    -- stale, but failing that, see about fetching.
    cache_expired = {
        { when = "checking_cache", begin = "checking_can_serve_stale" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch" },
        { when = "checking_can_serve_stale", begin = "checking_can_fetch" },
    },

    -- We have a (not expired) cache entry. Lets try and validate in case we can
    -- exit 304.
    cache_valid = {
        { in_case = "forced_cache", begin = "considering_esi_process" },
        {
            in_case = "collapsed_response_ready",
            begin = "considering_local_revalidation"
        },
        { when = "checking_cache", begin = "considering_revalidation" },
    },

    -- We need to fetch, and there are no settings telling us we shouldn't, but
    -- collapsed forwarding is on, so if cache is accepted and in an "expired"
    -- state (i.e. not missing), lets try to collapse. Otherwise we just start
    -- fetching.
    can_fetch_but_try_collapse = {
        { in_case = "cache_missing", begin = "fetching" },
        { in_case = "cache_accepted", begin = "requesting_collapse_lock" },
        { begin = "fetching" },
    },

    -- We have the lock on this "fetch". We might be the only one. We'll never
    -- know. But we fetch as "surrogate" in case others are listening.
    obtained_collapsed_forwarding_lock = {
        { begin = "fetching_as_surrogate" },
    },

    -- Another request is currently fetching, so we've subscribed to updates on
    -- this URI. We need to block until we hear something (or timeout).
    subscribed_to_collapsed_forwarding_channel = {
        { begin = "waiting_on_collapsed_forwarding_channel" },
    },

    -- Another request was fetching when we asked, but by the time we subscribed
    -- the channel was closed (small window, but potentially possible). Chances
    -- are the item is now in cache, so start there.
    collapsed_forwarding_channel_closed = {
        { begin = "checking_cache" },
    },

    -- We were waiting on a collapse channel, and got a message saying the
    -- response is now ready. The item will now be fresh in cache.
    collapsed_response_ready = {
        { begin = "checking_cache" },
    },

    -- We were waiting on another request (collapsed), but it came back as a
    -- non-cacheable response (i.e. the previously cached item is no longer
    -- cacheable). So go fetch for ourselves.
    collapsed_forwarding_failed = {
        { begin = "fetching" },
    },

    -- We were waiting on another request, but it received an upstream_error
    -- (e.g. 500) Check if we can serve stale content instead
    collapsed_forwarding_upstream_error = {
        { begin = "considering_stale_error" },
    },

    -- We need to fetch and nothing is telling us we shouldn't.
    -- Collapsed forwarding is not enabled.
    can_fetch = {
        { begin = "fetching" },
    },

    -- We've fetched and got a response status and headers. We should consider
    -- potential for ESI before doing anything else.
    response_fetched = {
        { begin = "considering_esi_scan" },
    },

    partial_response_fetched = {
        { begin = "considering_background_fetch" },
    },

    -- We had a partial response and were able to schedule a backgroud fetch for
    -- the complete resource.
    can_fetch_in_background = {
        {
            in_case = "partial_response_fetched",
            begin = "considering_esi_scan",
            but_first = "fetch_in_background"
        },
    },

    -- We had a partial response but skipped background fetching the complete
    -- resource, most likely because it is bigger than cache_max_memory.
    background_fetch_skipped = {
        {
            in_case = "partial_response_fetched",
            begin = "considering_esi_scan"
        },
    },

    -- If we went upstream and errored, check if we can serve a cached copy
    -- (stale-if-error), publish the error first if we were the surrogate
    -- request
    upstream_error = {
        {
            after = "fetching_as_surrogate",
            begin = "publishing_collapse_upstream_error"
        },
        { in_case = "cache_not_accepted", begin = "serving_upstream_error" },
        { in_case = "cache_missing", begin = "serving_upstream_error" },
        { begin = "considering_stale_error" }
    },

    -- We had an error from upstream and could not serve stale content, so serve
    -- the error.
    -- Or we were collapsed and the surrogate received an error but we could not
    -- serve stale in that case, try and fetch ourselves
    can_serve_upstream_error = {
        { after = "fetching", begin = "serving_upstream_error" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "fetching" },
        { begin = "serving_upstream_error" },
    },

    -- We've determined we need to scan the body for ESI.
    esi_scan_enabled = {
        {
            begin = "considering_gzip_inflate",
            but_first = "set_esi_scan_enabled"
        },
    },

    -- We've determined no need to scan the body for ESI.
    esi_scan_disabled = {
        { begin = "updating_cache", but_first = "set_esi_scan_disabled" },
    },

    gzip_inflate_enabled = {
        {
            after = "updating_cache",
            begin = "preparing_response",
            but_first = "install_gzip_decoder"
        },
        {
            in_case = "esi_scan_enabled",
            begin = "updating_cache",
            but_first = { "install_gzip_decoder", "install_esi_scan_filter" }
        },
        { begin = "preparing_response", but_first = "install_gzip_decoder" },
    },

    gzip_inflate_disabled = {
        { after = "updating_cache", begin = "preparing_response" },
        {
            after = "considering_esi_scan",
            in_case = "esi_scan_enabled",
            begin = "updating_cache",
            but_first = { "install_esi_scan_filter" }
        },
        { in_case = "esi_process_disabled", begin = "checking_range_request" },
        { begin = "preparing_response" },
    },

    range_accepted = {
        { begin = "preparing_response", but_first = "install_range_filter" },
    },

    range_not_accepted = {
        { begin = "preparing_response" },
    },

    range_not_requested = {
        { begin = "preparing_response" },
    },

    -- We deduced that the new response can cached. We always "save_to_cache".
    -- If we were fetching as a surrogate (collapsing) make sure we tell any
    -- others concerned. If we were performing a background revalidate (having
    -- served stale), we can just exit. Otherwise go back through validationg
    -- in case we can 304 to the client.
    response_cacheable = {
        {
            after = "fetching_as_surrogate",
            begin = "publishing_collapse_success",
            but_first = "save_to_cache"
        },
        {
            begin = "considering_local_revalidation",
            but_first = "save_to_cache"
        },
    },

    -- We've deduced that the new response cannot be cached. Essentially this is
    -- as per "response_cacheable", except we "delete" rather than "save", and
    -- we don't try to revalidate.
    response_not_cacheable = {
        {
            after = "fetching_as_surrogate",
            begin = "publishing_collapse_failure",
            but_first = "delete_from_cache"
        },
        { begin = "considering_esi_process", but_first = "delete_from_cache" },
    },

    -- A missing response body means a HEAD request or a 304 Not Modified
    -- upstream response, for example. If we were revalidating upstream, we can
    -- now re-revalidate against local cache. If we're collapsing or background
    -- revalidating, ensure we either clean up the collapsees or exit
    -- respectively.
    response_body_missing = {
        {
            in_case = "must_revalidate",
            begin = "considering_local_revalidation"
        },
        {
            after = "fetching_as_surrogate",
            begin = "publishing_collapse_failure",
            but_first = "delete_from_cache"
        },
        {
            begin = "serving",
                but_first = {
                    "install_no_body_reader", "set_http_status_from_response"
                },
        },
    },

    -- We were the collapser, so digressed into being a surrogate. We're done
    -- now and have published this fact, so we pick up where it would have left
    -- off - attempting to 304 to the client. Unless we received an error, in
    -- which case check if we can serve stale instead.
    published = {
        { in_case = "upstream_error", begin = "considering_stale_error" },
        { begin = "considering_local_revalidation" },
    },

    -- Client requests a max-age of 0 or stored response requires revalidation.
    must_revalidate = {
        { begin = "checking_can_fetch" },
    },

    -- We can validate locally, so do it. This doesn't imply it's valid, merely
    -- that we have the correct parameters to attempt validation.
    can_revalidate_locally = {
        { begin = "revalidating_locally" },
    },

    -- Standard non-conditional request.
    no_validator_present = {
        { begin = "considering_esi_process" },
    },

    -- The response has not been modified against the validators given. We'll
    -- exit 304 if we can but go via considering_esi_process in case of ESI work
    -- to be done.
    not_modified = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
    },

    -- Our cache has been modified as compared to the validators. But cache is
    -- valid, so just serve it. If we've been upstream, re-compare against
    -- client validators.
    modified = {
        { when = "revalidating_locally", begin = "considering_esi_process" },
    },

    esi_process_enabled = {
        {
            in_case = "can_serve_stale",
            begin = "serving_stale",
            but_first = {
                "install_esi_process_filter",
                "set_esi_process_enabled",
                "zero_downstream_lifetime",
                "remove_surrogate_control_header"
            }
        },
        {
            begin = "preparing_response",
            but_first = {
                "install_esi_process_filter",
                "set_esi_process_enabled",
                "zero_downstream_lifetime",
                "remove_surrogate_control_header"
            }
        },
    },

    esi_process_disabled = {
        {
            begin = "considering_gzip_inflate",
            but_first = "set_esi_process_disabled"
        },
    },

    esi_process_not_required = {
        {
            begin = "considering_gzip_inflate",
            but_first = {
                "set_esi_process_disabled",
                "remove_surrogate_control_header"
            },
        },
    },

    can_serve_disconnected = {
        {
            begin = "considering_esi_process",
            but_first = "add_disconnected_warning"
        },
    },

    -- We've deduced we can serve a stale version of this URI. Ensure we add a
    -- warning to the response headers.
    can_serve_stale = {
        {
            after = "considering_stale_error",
            begin = "considering_esi_process",
            but_first = "add_stale_warning"
        },
        {
            begin = "considering_revalidation",
            but_first = { "add_stale_warning" }
        },
    },

    -- We can serve stale, but also trigger a background revalidation
    can_serve_stale_while_revalidate = {
        {
            begin = "considering_esi_process",
            but_first = { "add_stale_warning", "revalidate_in_background" }
        },
    },

    -- We have a response we can use. If we've already served (we are doing
    -- background work) then just exit. If it has been prepared and we were
    -- not_modified, then set 304 and serve. If it has been prepared, set
    -- status accordingly and serve. If not, prepare it.
    response_ready = {
        {
            in_case = "served",
            begin = "exiting"
        },
        {
            in_case = "forced_cache",
            begin = "serving",
            but_first = "add_disconnected_warning"
        },

        -- If we might ESI, then don't 304 downstream.
        {
            when = "preparing_response",
            in_case = "esi_process_enabled",
            begin = "serving",
            but_first = "set_http_status_from_response"
        },
        {
            when = "preparing_response",
            in_case = "not_modified",
            after = "fetching",
            begin = "serving",
            but_first = {
                "set_http_not_modified",
                "disable_output_buffers"
            }
        },
        {
            when = "preparing_response",
            in_case = "not_modified",
            begin = "serving",
            but_first = {
                "set_http_not_modified",
                "install_no_body_reader"
            }
        },
        {
            when = "preparing_response",
            begin = "serving",
            but_first = "set_http_status_from_response"
        },
        {
            begin = "preparing_response"
        },
    },

    -- We have sent the response. If it was stale, we go back around the
    -- fetching path so that a background revalidation can occur unless the
    -- upstream errored. Otherwise exit.
    served = {
        { in_case = "upstream_error", begin = "exiting" },
        { in_case = "collapsed_forwarding_upstream_error", begin = "exiting" },
        { in_case = "response_cacheable", begin = "exiting" },
        { begin = "exiting" },
    },

    -- When the client request is aborted clean up redis / http connections.
    -- If we're saving or have the collapse lock, then don't abort as we want
    -- to finish regardless.
    -- Note: this is a special entry point, triggered by ngx_lua client abort
    -- notification.
    aborted = {
        { in_case = "response_cacheable", begin = "cancelling_abort_request" },
        {
            in_case = "obtained_collapsed_forwarding_lock",
            begin = "cancelling_abort_request"
        },
        { begin = "exiting" },
    },


    -- Useful events for exiting with a common status. If we've already served
    -- (perhaps we're doing background work, we just exit without re-setting the
    -- status (as this errors).

    http_gateway_timeout = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_gateway_timeout" },
    },

    http_service_unavailable = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_service_unavailable" },
    },

    http_internal_server_error = {
        { in_case = "served", begin = "exiting" },
        { begin = "exiting", but_first = "set_http_internal_server_error" },
    },
}
