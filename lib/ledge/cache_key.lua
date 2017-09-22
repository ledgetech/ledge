local ipairs, next, type, pcall, setmetatable =
      ipairs, next, type, pcall, setmetatable

local str_lower = string.lower

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_var = ngx.var
local ngx_null = ngx.null

local tbl_insert = table.insert
local tbl_concat = table.concat

local req_args_sorted = require("ledge.request").args_sorted
local req_default_args = require("ledge.request").default_args

local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy


local _M = {
    _VERSION = "2.0.0",
}


-- Generates the root key. The default spec is:
-- ledge:cache_obj:http:example.com:/about:p=3&q=searchterms
local function generate_root_key(key_spec, max_args)
    -- If key_spec is empty, provide a default
    if not key_spec or not next(key_spec) then
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
_M.generate_root_key = generate_root_key


-- Read the list of vary headers from redis
local function read_vary_spec(redis, root_key)
    if not redis or not next(redis) then
        return nil, "Redis required"
    end

    if not root_key then
        return nil, "Root key required"
    end

    local res, err = redis:smembers(root_key.."::vary")
    if err then
        return nil, err
    end

    return res
end
_M.read_vary_spec = read_vary_spec


local function vary_spec_compare(spec_a, spec_b)
    if (not spec_a or not next(spec_a)) then
        if (not spec_b or not next(spec_b)) then
            -- both nil or empty
            return false
        else
            -- spec_b is set but spec_a is empty
            return true
        end

    elseif (spec_b and next(spec_b)) then
        -- TODO: looping here faster?
        if str_lower(tbl_concat(spec_b, ",")) == str_lower(tbl_concat(spec_a, ",")) then
            -- Current vary spec and new vary spec match
            return false
        end
    end

    -- spec_a is a thing but spec_b is not
    return true
end
_M.vary_spec_compare = vary_spec_compare


local function generate_vary_key(vary_spec, callback, headers)
    local vary_key = {}

    if vary_spec and next(vary_spec) then
        headers = headers or ngx.req.get_headers()

        for _, h in ipairs(vary_spec) do
            local v = headers[h]
            if type(v) == "table" then
                v = tbl_concat(v, ",")
            end
            -- ngx.null represents a key which was in the spec
            -- but has no matching request header
            vary_key[h] = v or ngx_null
        end
    end

    -- Callback allows user to modify the key
    if type(callback) == "function" then
        callback(vary_key)
    end

    if not next(vary_key) then
        return ""
    end

    -- Convert hash table to array
    local t = {}
    local i = 1
    for k,v in pairs(vary_key) do
        if v ~= ngx_null then
            t[i] = k
            t[i+1] = v
            i = i+2
        end
    end

    return str_lower(tbl_concat(t, ":"))
end
_M.generate_vary_key = generate_vary_key


-- Returns the key chain for all cache keys, except the body entity
local function key_chain(root_key, vary_key, vary_spec)
    if not root_key then
        return nil, "Missing root key"
    end
    if not vary_key then
        return nil, "Missing vary key"
    end
    if not vary_spec then
        return nil, "Missing vary_spec"
    end


    local full_key = root_key .. "#" .. vary_key

    -- Apply metatable
    local key_chain = setmetatable({
            -- set: headers upon which to vary
            vary   = root_key .. "::vary",

            -- set: representations for this root key
            repset = root_key .. "::repset",

            -- hash: cache key metadata
            main = full_key .. "::main",

            -- sorted set: current entities score with sizes
            entities = full_key .. "::entities",

            -- hash: response headers
            headers = full_key .. "::headers",

            -- hash: request headers for revalidation
            reval_params = full_key .. "::reval_params",

            -- hash: request params for revalidation
            reval_req_headers = full_key .. "::reval_req_headers",
        }, get_fixed_field_metatable_proxy({
            -- Hide "root", "full", the "vary_spec" and "fetching_lock" from iterators.
            root = root_key,
            full = full_key,
            vary_spec = vary_spec,
            fetching_lock = full_key .. "::fetching",
        })
    )

    return key_chain
end
_M.key_chain = key_chain


local function clean_repset(redis, repset)
    -- Ensure representation set only includes keys which actually exist
    -- This only runs on the slow path at save time so should be ok?
    -- Prevents this set from growing perpetually if there are unique variations
    -- TODO use scan here incase the set is pathologically huge?
    -- Has to be able to run in a transaction so maybe a housekeeping qless job?
    local clean = [[
    local repset = KEYS[1]
    local reps = redis.call("SMEMBERS", repset)
    for _, rep in ipairs(reps) do
        if redis.call("EXISTS", rep.."::main") == 0 then
            redis.call("SREM", repset, rep)
        end
    end
    ]]

    local res, err = redis:eval(clean, 1, repset)
    if not res or res == ngx_null then
        return nil, err
    end

    return true
end


local function save_key_chain(redis, key_chain, ttl)
    if not redis then
        return nil, "Redis required"
    end

    if type(key_chain) ~= "table" or not next(key_chain) then
        return nil, "Key chain required"
    end

    if not tonumber(ttl) then
        return nil, "TTL must be a number"
    end

    -- Delete the current set of vary headers
    local _, e = redis:del(key_chain.vary)
    if e then ngx_log(ngx_ERR, e) end

    local vary_spec = key_chain.vary_spec

    if next(vary_spec) then
        -- Always lowercase all vary fields
        -- key_chain.vary is a set so will deduplicate for us
        for i,v in ipairs(vary_spec) do
            vary_spec[i] = str_lower(v)
        end

        local _, e = redis:sadd(key_chain.vary, unpack(vary_spec))
        if e then ngx_log(ngx_ERR, e) end

        local _, e = redis:expire(key_chain.vary, ttl)
        if e then ngx_log(ngx_ERR, e) end
    end

    -- Add this representation to the set
    local _, e = redis:sadd(key_chain.repset, key_chain.full)
    if e then ngx_log(ngx_ERR, e) end

    local _, e = redis:expire(key_chain.repset, ttl)
    if e then ngx_log(ngx_ERR, e) end


    local _, e = clean_repset(redis, key_chain.repset)
    if e then ngx_log(ngx_ERR, e) end

    return true
end
_M.save_key_chain = save_key_chain


return _M
