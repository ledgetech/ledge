local h_util = require "ledge.header_util"

local type, tonumber = type, tonumber

local str_sub = string.sub
local str_find = string.find

local tbl_concat = table.concat
local tbl_insert = table.insert

local ngx_re_match = ngx.re.match
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_encode_args = ngx.encode_args
local ngx_req_set_uri_args = ngx.req.set_uri_args
local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR


local _M = {
    _VERSION = "2.1.4",
}


local esi_processors = {
    ["ESI"] = {
        ["1.0"] = require "ledge.esi.processor_1_0",
        -- 2.0 = require ledge.esi.processor_2_0", -- for example
    },
}


function _M.split_esi_token(token)
    if token then
        local m = ngx_re_match(
            token,
            [[^([A-Za-z0-9-_]+)\/(\d+\.?\d+)$]],
            "oj"
        )
        if m then
            return m[1], tonumber(m[2])
        end
    end
end


function _M.esi_capabilities()
    local capabilities = {}
    for processor_type,processors in pairs(esi_processors) do
        for version,_ in pairs(processors) do
            tbl_insert(capabilities, processor_type .. "/" .. version)
        end
    end
    return tbl_concat(capabilities, " ")
end


-- Returns a processor instance based on Surrogate-Control header
function _M.choose_esi_processor(handler)
    local res = handler.response
    local res_surrogate_control = res.header["Surrogate-Control"]

    if res_surrogate_control then
        -- Get the token value (e.g. "ESI/1.0")
        local content_token =
            h_util.get_header_token(res_surrogate_control, "content")

        if content_token then
            local processor_token, version = _M.split_esi_token(content_token)

            if processor_token and version then
                -- Lookup the prcoessor
                local processor_type = esi_processors[processor_token]

                if processor_type then
                    for v,processor in pairs(processor_type) do
                        if tonumber(version) <= tonumber(v) then
                            return processor.new(handler)
                        end
                    end
                end
            end
        end
    end
end


-- Returns true of res.header.Content-Type is in allowed_types
function _M.is_allowed_content_type(res, allowed_types)
    if allowed_types and type(allowed_types) == "table" then
        local res_content_type = res.header["Content-Type"]
        if res_content_type then
            for _, content_type in ipairs(allowed_types) do
                local sep = str_find(res_content_type, ";")
                if sep then sep = sep - 1 end
                if str_sub(res_content_type, 1, sep) == content_type then
                    return true
                end
            end
        end
    end
end


-- Returns true if we're allowed to delegate ESI processing to a downstream
-- surrogate for the current request
function _M.can_delegate_to_surrogate(surrogates, processor_token)
    local surrogate_capability = ngx_req_get_headers()["Surrogate-Capability"]

    if surrogate_capability then
        -- Surrogate-Capability: host.example.com="ESI/1.0"
        local capability_token = h_util.get_header_token(
            surrogate_capability,
            "[!#\\$%&'\\*\\+\\-.\\^_`\\|~0-9a-zA-Z]+"
        )

        local capability_processor, capability_version =
            _M.split_esi_token(capability_token)

        if capability_processor and capability_version then
            local control_processor, control_version =
                _M.split_esi_token(processor_token)

            if control_processor and control_version
                and control_processor == capability_processor
                and control_version <= capability_version then

                if type(surrogates) == "boolean" then
                    if surrogates == true then
                        return true
                    end
                elseif type(surrogates) == "table" then
                    local remote_addr = ngx_var.remote_addr
                    if remote_addr then
                        for _, ip in ipairs(surrogates) do
                            if ip == remote_addr then
                                return true
                            end
                        end
                    end
                end
            end
        end
    end

    return false
end


function _M.filter_esi_args(handler)
    local config = handler.config
    local esi_args_prefix = config.esi_args_prefix
    if esi_args_prefix then
        local args = ngx_req_get_uri_args(config.max_uri_args)
        local esi_args = {}
        local has_esi_args = false
        local non_esi_args = {}

        for k,v in pairs(args) do
            -- TODO: optimise
            -- If we have the prefix, extract the suffix
            local m, err = ngx_re_match(
                k,
                "^" .. esi_args_prefix .. "(\\S+)",
                "oj"
            )
            if err then ngx_log(ngx_ERR, err) end

            if m and m[1] then
                has_esi_args = true
                esi_args[m[1]] = v
            else
                -- Otherwise, this is a normal arg
                non_esi_args[k] = v
            end
        end

        if has_esi_args then
            -- Add them to ctx to be read by the esi processor, along with a
            -- __tostsring metamethod for the $(ESI_ARGS) string case
            ngx.ctx.__ledge_esi_args = setmetatable(esi_args, {
                __tostring = function(t)
                    local args = {}
                    for k,v in pairs(t) do
                        args[esi_args_prefix .. k] = v
                    end
                    return ngx_encode_args(args)
                end
            })

            -- Set the request args to the ones left over
            ngx_req_set_uri_args(non_esi_args)
        end
    end
end


return _M
