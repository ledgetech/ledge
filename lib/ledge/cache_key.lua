local ipairs, next, type, pcall, setmetatable =
      ipairs, next, type, pcall, setmetatable

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_var = ngx.var

local tbl_insert = table.insert
local tbl_concat = table.concat

local req_args_sorted = require("ledge.request").args_sorted
local req_default_args = require("ledge.request").default_args

local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _M = {
    _VERSION = "2.0.0",
}


-- Generates the cache key. The default spec is:
-- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
local function generate_cache_key(key_spec, max_args)
    -- If key_spec is empty, provide a default
    if not next(key_spec) then
        key_spec = {
            "scheme",
            "host",
            "uri",
            "args",
        }
    end

    local key = {
        "ledge",
        "cache",
    }

    for _, field in ipairs(key_spec) do
        if field == "scheme" then
            tbl_insert(key, ngx_var.scheme)
        elseif field == "host" then
            tbl_insert(key, ngx_var.host)
        elseif field == "port" then
            tbl_insert(key, ngx_var.server_port)
        elseif field == "uri" then
            tbl_insert(key, ngx_var.uri)
        elseif field == "args" then
            tbl_insert(
                key,
                req_args_sorted(max_args) or req_default_args()
            )

        elseif type(field) == "function" then
            local ok, res = pcall(field)
            if not ok then
                ngx_log(ngx_ERR,
                    "error in function supplied to cache_key_spec: ", res
                )
            elseif type(res) ~= "string" then
                ngx_log(ngx_ERR,
                    "functions supplied to cache_key_spec must " ..
                    "return a string"
                )
            else
                tbl_insert(key, res)
            end
        end
    end

    return tbl_concat(key, ":")
end
_M.generate_cache_key = generate_cache_key


-- Returns the key chain for all cache keys, except the body entity
local function key_chain(cache_key)
    return setmetatable({
        -- hash: cache key metadata
        main = cache_key .. "::main",

        -- sorted set: current entities score with sizes
        entities = cache_key .. "::entities",

        -- hash: response headers
        headers = cache_key .. "::headers",

        -- hash: request headers for revalidation
        reval_params = cache_key .. "::reval_params",

        -- hash: request params for revalidation
        reval_req_headers = cache_key .. "::reval_req_headers",

    }, get_fixed_field_metatable_proxy({
        -- Hide "root" and "fetching_lock" from iterators.
        root = cache_key,
        fetching_lock = cache_key .. "::fetching",
    }))
end
_M.key_chain = key_chain


return _M
