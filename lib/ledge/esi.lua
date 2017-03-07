local http = require "resty.http"
local cookie = require "resty.cookie"
local h_util = require "ledge.header_util"
local tag_parser = require "ledge.esi.tag_parser"
require "ledge.util"

local   tostring, type, tonumber, next, unpack, pcall, setfenv =
        tostring, type, tonumber, next, unpack, pcall, setfenv

local str_sub = string.sub
local str_find = string.find
local str_len = string.len
local str_split = string.split

local tbl_concat = table.concat
local tbl_insert = table.insert

local co_yield = coroutine.yield
local co_wrap = coroutine.wrap

local ngx_re_gsub = ngx.re.gsub
local ngx_re_sub = ngx.re.sub
local ngx_re_match = ngx.re.match
local ngx_re_gmatch = ngx.re.gmatch
local ngx_re_find = ngx.re.find
local ngx_req_get_headers = ngx.req.get_headers
local ngx_req_get_method = ngx.req.get_method
local ngx_req_get_uri_args = ngx.req.get_uri_args
local ngx_crc32_long = ngx.crc32_long
local ngx_encode_args = ngx.encode_args
local ngx_req_set_uri_args = ngx.req.set_uri_args
local ngx_flush = ngx.flush
local ngx_var = ngx.var
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO


local _M = {
    _VERSION = '1.28.3',
}


local mt = {
    __index = _M,
    __newindex = function() error("module fields are read only", 2) end,
    __metatable = false,
}


function _M.new(content, offset)
    return setmetatable({
    }, mt)
end


local esi_processors = {
    ["ESI"] = {
        ["1.0"] = require "ledge.esi.processor_1_0",
        -- 2.0 = require ledge.esi.processor_2_0", -- for example
    },
}


function _M.split_esi_token(token)
    return unpack(str_split(token, "/") or {})
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
function _M.choose_esi_processor(res)
    local res_surrogate_control = res.header["Surrogate-Control"]
    if res_surrogate_control then
        -- Get the token value (e.g. "ESI/1.0")
        local content_token = h_util.get_header_token(res_surrogate_control, "content")

        if content_token then
            local processor_token, version = _M.split_esi_token(content_token)

            if processor_token and version then
                -- Lookup the prcoessor
                local processor_type = esi_processors[processor_token]

                if processor_type then
                    for v,processor in pairs(processor_type) do
                        if tonumber(version) <= tonumber(v) then
                            return processor.new()
                        end
                    end
                end
            end
        end
    end
end


-- Returns true of res.header.Content-Type is in allowed_types
function _M.allowed_content_type(res, allowed_types)
    if allowed_types and type(allowed_types) == "table" then
        local res_content_type = res.header["Content-Type"]
        if res_content_type then
            for _, content_type in ipairs(allowed_types) do
                if str_sub(res_content_type, 1, str_len(content_type)) == content_type then
                    return true
                end
            end
        end
    end
end


-- Returns true if we're allowed to delegate ESI processing to a downstream
-- surrogate for the current request
function _M.delegate_to_surrogate(surrogates, processor_token)
    local surrogate_capability = ngx_req_get_headers()["Surrogate-Capability"]

    if surrogate_capability then
        -- Surrogate-Capability: host.example.com="ESI/1.0"
        local capability_token = h_util.get_header_token(
            surrogate_capability,
            "[!#\\$%&'\\*\\+\\-.\\^_`\\|~0-9a-zA-Z]+"
        )
        local capability_processor, capability_version = _M.split_esi_token(capability_token)
        capability_version = tonumber(capability_version)

        if capability_processor and capability_version then
            local control_processor, control_version = _M.split_esi_token(processor_token)
            control_version = tonumber(control_version)

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


function _M.filter_esi_args(esi_args_prefix)
    if esi_args_prefix then
        local args = ngx_req_get_uri_args()
        local esi_args = {}
        local has_esi_args = false
        local non_esi_args = {}

        for k,v in pairs(args) do
            -- If we have the prefix, extract the suffix
            local m, err = ngx_re_match(k, "^" .. esi_args_prefix .. "(\\S+)", "oj")
            if m and m[1] then
                has_esi_args = true
                esi_args[m[1]] = v
            else
                -- Otherwise, this is a normal arg
                non_esi_args[k] = v
            end
        end

        if has_esi_args then
            -- Add them to esi_custom_variables
            local custom_variables = ngx.ctx.ledge_esi_custom_variables
            if not custom_variables then custom_variables = {} end
            custom_variables["ESI_ARGS"] = esi_args
            ngx.ctx.ledge_esi_custom_variables = custom_variables

            -- Also keep them in encoded querystring form, so that $(ESI_ARGS) works
            -- as a string.
            ngx.ctx.ledge_esi_args_prefix = esi_args_prefix
            local args = {}
            for k,v in pairs(esi_args) do
                args[esi_args_prefix .. k] = v
            end
            ngx.ctx.ledge_esi_args_encoded = ngx_encode_args(args)

            -- Set the request args to the ones left over
            ngx_req_set_uri_args(non_esi_args)
        end
    end
end


return _M
