local ffi = require "ffi"

local type, next, setmetatable, getmetatable =
        type, next, setmetatable, getmetatable

local str_gmatch = string.gmatch
local tbl_insert = table.insert
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume
local math_floor = math.floor
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C


ffi_cdef[[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
]]


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
string.randomhex = randomhex


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
table.copy = tbl_copy


local function str_split(str, delim)
    if not str or not delim then return nil end
    local it, err = str_gmatch(str, "([^"..delim.."]+)")
    if it then
        local output = {}
        while true do
            local m, err = it()
            if not m then
                break
            end
            tbl_insert(output, m)
        end
        return output
    end
end
string.split = str_split


local function co_wrap(func)
    local co = co_create(func)
    if not co then
        return nil, "could not create coroutine"
    else
        return function(...)
            if co_status(co) == "suspended" then
                return select(2, co_resume(co, ...))
            else
                return nil, "can't resume a " .. co_status(co) .. " coroutine"
            end
        end
    end
end
coroutine.wrap = co_wrap
