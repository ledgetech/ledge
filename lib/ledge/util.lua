local ngx_var = ngx.var
local ffi = require "ffi"

local type, next, setmetatable, getmetatable, error, tostring =
        type, next, setmetatable, getmetatable, error, tostring

local str_find = string.find
local str_sub = string.sub
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume
local math_floor = math.floor
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C


local ok, err = pcall(ffi_cdef, [[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
]])
if not ok then ngx.log(ngx.ERR, err) end

local ok, err = pcall(ffi_cdef, [[
int gethostname (char *name, size_t size);
]])
if not ok then ngx.log(ngx.ERR, err) end


local _M = {
    _VERSION = "2.1.1",
    string = {},
    table = {},
    mt = {},
    coroutine = {},
}


local function randomhex(len)
    local len = math_floor(len / 2)

    local bytes = ffi_new("uint8_t[?]", len)
    C.RAND_pseudo_bytes(bytes, len)
    if not bytes then
        return nil, "error getting random bytes via FFI"
    end

    local hex = ffi_new("uint8_t[?]", len * 2)
    C.ngx_hex_dump(hex, bytes, len)
    return ffi_string(hex, len * 2)
end
_M.string.randomhex = randomhex


local function str_split(str, delim)
    local pos, endpos, prev, i = 0, 0, 0, 0 -- luacheck: ignore pos endpos
    local out = {}
    repeat
        pos, endpos = str_find(str, delim, prev, true)
        i = i+1
        if pos then
            out[i] = str_sub(str, prev, pos-1)
        else
            if prev <= #str then
                out[i] = str_sub(str, prev, -1)
            end
            break
        end
        prev = endpos +1
    until pos == nil

    return out
end
_M.string.split = str_split


-- A metatable which prevents undefined fields from being created / accessed
local fixed_field_metatable = {
    __index =
        function(t, k) -- luacheck: no unused
            error("field " .. tostring(k) .. " does not exist", 3)
        end,
    __newindex =
        function(t, k, v) -- luacheck: no unused
            error("attempt to create new field " .. tostring(k), 3)
        end,
}
_M.mt.fixed_field_metatable = fixed_field_metatable


-- Returns a metatable with fixed fields (as above), which when applied to a
-- table will provide default values via the provided `proxy`. E.g:
--
-- defaults = { a = 1, b = 2, c = 3 }
-- t = setmetatable({ b = 4 }, get_fixed_field_metatable_proxy(defaults))
--
-- `t` now gives: { a = 1, b = 4, c = 3 }
--
-- @param   table   proxy table
-- @return  table   metatable
local function get_fixed_field_metatable_proxy(proxy)
    return {
        __index =
            function(t, k) -- luacheck: no unused
                return proxy[k] or
                    error("field " .. tostring(k) .. " does not exist", 2)
            end,
        __newindex =
            function(t, k, v)
                if proxy[k] then
                    return rawset(t, k, v)
                else
                    error("attempt to create new field " .. tostring(k), 2)
                end
            end,
    }
end
_M.mt.get_fixed_field_metatable_proxy = get_fixed_field_metatable_proxy


-- Returns a metatable with fixed fields (as above), which when invoked as a
-- function will call the supplied `func`. E.g.:
--
-- t = setmetatable(
--      { a = 1, b = 2, c = 3 },
--      get_callable_fixed_field_metatable(
--          function(t, field)
--              print(t[field])
--          end
--      )
-- )
-- t("a")  -- 1
-- t("b")  -- 2
--
-- @param   function
-- @return  table   callable metatable
local function get_callable_fixed_field_metatable(func)
    local mt = fixed_field_metatable
    mt.__call = func
    return mt
end
_M.mt.get_callable_fixed_field_metatable = get_callable_fixed_field_metatable


-- Returns a new table, recursively copied from the one given, retaining
-- metatable assignment.
--
-- @param   table   table to be copied
-- @return  table
local function tbl_copy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == "table" then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[tbl_copy(orig_key)] = tbl_copy(orig_value)
        end
        setmetatable(copy, tbl_copy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end
_M.table.copy = tbl_copy


-- Returns a new table, recursively copied from the combination of the given
-- table `t1`, with any missing fields copied from `defaults`.
--
-- If `defaults` is of type "fixed field" and `t1` contains a field name not
-- present in the defults, an error will be thrown.
--
-- @param   table   t1
-- @param   table   defaults
-- @return  table   a new table, recursively copied and merged
local function tbl_copy_merge_defaults(t1, defaults)
    if t1 == nil then t1 = {} end
    if defaults == nil then defaults = {} end
    if type(t1) == "table" and type(defaults) == "table" then
        local copy = {}
        for t1_key, t1_value in next, t1, nil do
            copy[tbl_copy(t1_key)] = tbl_copy_merge_defaults(
                t1_value, tbl_copy(defaults[t1_key])
            )
        end
        for defaults_key, defaults_value in next, defaults, nil do
            if t1[defaults_key] == nil then
                copy[tbl_copy(defaults_key)] = tbl_copy(defaults_value)
            end
        end
        return copy
    else
        return t1 -- not a table
    end
end
_M.table.copy_merge_defaults = tbl_copy_merge_defaults


local function co_wrap(func)
    local co = co_create(func)
    if not co then
        return nil, "could not create coroutine"
    else
        return function(...)
            if co_status(co) == "suspended" then
                -- Handle errors in coroutines
                local ok, val1, val2, val3 = co_resume(co, ...)
                if ok == true then
                    return val1, val2, val3
                else
                    return nil, val1
                end
            else
                return nil, "can't resume a " .. co_status(co) .. " coroutine"
            end
        end
    end
end
_M.coroutine.wrap = co_wrap


local function get_hostname()
    local name = ffi_new("char[?]", 255)
    C.gethostname(name, 255)
    return ffi_string(name)
end
_M.get_hostname = get_hostname


local function append_server_port(name)
    -- TODO: compare with scheme?
    local server_port = ngx_var.server_port
    if server_port ~= "80" and server_port ~= "443" then
        name = name .. ":" .. server_port
    end
    return name
end
_M.append_server_port = append_server_port


return _M
