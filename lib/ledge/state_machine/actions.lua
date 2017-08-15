local type, next = type, next

local esi = require("ledge.esi")
local response = require("ledge.response")

local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_INFO = ngx.INFO

local ngx_HTTP_NOT_MODIFIED = ngx.HTTP_NOT_MODIFIED

local ngx_req_set_header = ngx.req.set_header

local get_gzip_decoder = require("ledge.gzip").get_gzip_decoder

local fixed_field_metatable = require("ledge.util").mt.fixed_field_metatable


local _M = {
    _VERSION = "1.28.3",
}


-- Actions. Functions which can be called on transition.
return {
    redis_close = function(handler)
        return require("ledge").close_redis_connection(handler.redis)
    end,

    httpc_close = function(handler)
        local upstream_client = handler.upstream_client
        if next(upstream_client) then
            if type(upstream_client.set_keepalive) == "function" then
                local config = handler.config
                return upstream_client:set_keepalive(
                    config.upstream_keepalive_timeout,
                    config.upstream_keepalive_poolsize
                )
            end
        end
    end,

    stash_error_response = function(handler)
        handler.error_response = handler.response
    end,

    restore_error_response = function(handler)
        local error_res = handler.error_response
        if next(error_res) then
            handler.response = error_res
        end
    end,

    -- If ESI is enabled and we have an esi_args prefix, weed uri args
    -- beginning with the prefix (knows as ESI_ARGS) out of the URI (and thus
    -- cache key) and stash them in the custom ESI variables table.
    filter_esi_args = function(handler)
        if handler.config.esi_enabled then
            esi.filter_esi_args(handler)
        end
    end,

    read_cache = function(handler)
        handler.response = handler:read_from_cache()
    end,

    install_no_body_reader = function(handler)
        local res = handler.response
        res.body_reader = res.empty_body_reader
    end,

    install_gzip_decoder = function(handler)
        local res = handler.response
        res.header["Content-Encoding"] = nil
        res:filter_body_reader(
            "gzip_decoder",
            get_gzip_decoder(res.body_reader)
        )
    end,

    install_range_filter = function(handler)
        local res = handler.response
        local range = handler.range
        res:filter_body_reader(
            "range_request_filter",
            range:get_range_request_filter(res.body_reader)
        )
    end,

    set_esi_scan_enabled = function(handler)
        handler.esi_scan_enabled = true
        --handler.esi_scan_disabled = false
        handler.response.esi_scanned = true
    end,

    install_esi_scan_filter = function(handler)
        local res = handler.response
        local esi_processor = handler.esi_processor

        if next(esi_processor) then
            res:filter_body_reader(
                "esi_scan_filter",
                esi_processor:get_scan_filter(res)
            )
        end
    end,

    set_esi_scan_disabled = function(handler)
        local res = handler.response
        handler.esi_scan_enabled = false
        res.esi_scanned = false
    end,

    install_esi_process_filter = function(handler)
        local res = handler.response
        local esi_processor = handler.esi_processor

        if next(esi_processor) then
            res:filter_body_reader(
                "esi_process_filter",
                esi_processor:get_process_filter(res)
            )
        end
    end,

    set_esi_process_enabled = function(handler)
        handler.esi_process_enabled = true
    end,

    set_esi_process_disabled = function(handler)
        handler.esi_process_enabled = false
    end,

    zero_downstream_lifetime = function(handler)
        local res = handler.response
        if res.header then
            res.header["Cache-Control"] = "private, max-age=0"
        end
    end,

    remove_surrogate_control_header = function(handler)
        local res = handler.response
        if res.header then
            res.header["Surrogate-Control"] = nil
        end
    end,

    fetch = function(handler)
        local res = handler:fetch_from_origin()
        if res.status ~= ngx_HTTP_NOT_MODIFIED then
            handler.response = res
        end
    end,

    remove_client_validators = function(handler)
        -- Keep these in case we need to restore them (after revalidating upstream)
        local client_validators = handler.client_validators
        client_validators["If-Modified-Since"] = ngx_var.http_if_modified_since
        client_validators["If-None-Match"] = ngx_var.http_if_none_match

        ngx_req_set_header("If-Modified-Since", nil)
        ngx_req_set_header("If-None-Match", nil)
    end,

    restore_client_validators = function(handler)
        local client_validators = handler.client_validators
        ngx_req_set_header("If-Modified-Since", client_validators["If-Modified-Since"])
        ngx_req_set_header("If-None-Match", client_validators["If-None-Match"])
    end,

    add_validators_from_cache = function(handler)
        local cached_res = handler.response

        ngx_req_set_header("If-Modified-Since", cached_res.header["Last-Modified"])
        ngx_req_set_header("If-None-Match", cached_res.header["Etag"])
    end,

    add_stale_warning = function(handler)
        return handler:add_warning("110")
    end,

    add_transformation_warning = function(handler)
        return handler:add_warning("214")
    end,

    add_disconnected_warning = function(handler)
        return handler:add_warning("112")
    end,

    serve = function(handler)
        return handler:serve()
    end,

    set_json_response = function(handler)
        local res = response.new(handler.redis, handler:cache_key_chain())
        res.header["Content-Type"] = "application/json"
        handler.response = res
    end,

    -- Updates the realidation_params key with data from the current request,
    -- and schedules a background revalidation job
    revalidate_in_background = function(handler)
        return handler:revalidate_in_background(true)
    end,

    -- Triggered on upstream partial content, assumes no stored
    -- revalidation metadata but since we have a rqeuest context (which isn't
    -- the case with `revalidate_in_background` we can simply fetch.
    fetch_in_background = function(handler)
        return handler:fetch_in_background()
    end,

    save_to_cache = function(handler)
        local res = handler.response
        return handler:save_to_cache(res)
    end,

    delete_from_cache = function(handler)
        return handler:delete_from_cache()
    end,

    release_collapse_lock = function(handler)
        handler.redis:del(handler:cache_key_chain().fetching_lock)
    end,

    disable_output_buffers = function(handler)
        handler.output_buffers_enabled = false
    end,

    set_http_ok = function(handler)
        ngx.status = ngx.HTTP_OK
    end,

    set_http_not_found = function(handler)
        ngx.status = ngx.HTTP_NOT_FOUND
    end,

    set_http_not_modified = function(handler)
        ngx.status = ngx_HTTP_NOT_MODIFIED
    end,

    set_http_service_unavailable = function(handler)
        ngx.status = ngx.HTTP_SERVICE_UNAVAILABLE
    end,

    set_http_gateway_timeout = function(handler)
        ngx.status = ngx.HTTP_GATEWAY_TIMEOUT
    end,

    set_http_connection_timed_out = function(handler)
        ngx.status = 524
    end,

    set_http_internal_server_error = function(handler)
        ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    end,

    set_http_status_from_response = function(handler)
        local res = handler.response
        if res and res.status then
            ngx.status = res.status
        else
            ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
        end
    end,
}
