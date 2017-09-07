local _M = { -- luacheck: no unused
    _VERSION = "2.0.0",
}


-- Pre-transitions. These actions will *always* be performed before
-- transitioning.
return {
    exiting = { "redis_close", "httpc_close" },
    checking_cache = { "read_cache" },

    -- Never fetch with client validators, but put them back afterwards.
    fetching = {
        "remove_client_validators", "fetch", "restore_client_validators"
    },

    -- Need to save the error response before reading from cache in case we
    -- need to serve it later
    considering_stale_error = {
        "stash_error_response",
        "read_cache"
    },

    -- Restore the saved response and set the status when serving an error page
    serving_upstream_error = {
        "restore_error_response",
        "set_http_status_from_response"
    },
    serving_stale = {
        "set_http_status_from_response",
    },
    cancelling_abort_request = {
        "disable_output_buffers"
    },
}
