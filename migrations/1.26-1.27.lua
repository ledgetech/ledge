local redis_connector = require("resty.redis.connector").new()
local math_floor = math.floor
local math_ceil = math.ceil
local ffi = require "ffi"
local ffi_cdef = ffi.cdef
local ffi_new = ffi.new
local ffi_string = ffi.string
local C = ffi.C

ffi_cdef[[
typedef unsigned char u_char;
u_char * ngx_hex_dump(u_char *dst, const u_char *src, size_t len);
int RAND_pseudo_bytes(u_char *buf, int num);
]]


local function random_hex(len)
    local len = math_floor(len / 2)

    local bytes = ffi_new("uint8_t[?]", len)
    C.RAND_pseudo_bytes(bytes, len)
    if not bytes then
        ngx_log(ngx_ERR, "error getting random bytes via FFI")
        return nil
    end

    local hex = ffi_new("uint8_t[?]", len * 2)
    C.ngx_hex_dump(hex, bytes, len)
    return ffi_string(hex, len * 2)
end


function scan(cursor, redis)
    local res, err = redis:scan(
        cursor,
        "MATCH", "ledge:cache:*::key", -- We use the "main" key to single out a cache entry
        "COUNT", 100
    )

    if not res or res == ngx_null then
        return nil, "SCAN error: " .. tostring(err)
    else
        for _,key in ipairs(res[2]) do
            -- Strip the "main" suffix to find the cache key
            local cache_key = string.sub(key, 1, -(string.len("::key") + 1))
            ngx.print(".")

            local entity, err = redis:get(cache_key .. "::key")
            if not entity or entity == ngx.null then
                ngx.say(err)
                return
            end

            local memused, err = redis:get(cache_key .. "::memused")

            -- Move main entity to main key
            local ok, err = redis:rename(cache_key .. "::" .. entity, cache_key .. "::main")
            if not ok or ok == ngx.null then
                ngx.say("Renaming entity to main failed: ", err)
            end

            -- Rename headers etc
            for _, k in ipairs({ "headers", "reval_req_headers", "reval_params" }) do
                local ok, err = redis:rename(
                    cache_key .. "::" .. entity .. ":" .. k,
                    cache_key .. "::" .. k
                )
                if not ok or ok == ngx.null then
                    ngx.say("Renaming ", k, " failed: ", err)
                end
            end

            -- Create a new entity id and rename the live entity to it
            local new_entity_id = random_hex(32)
            for _, k in ipairs({ "body", "body_esi" }) do
                local ok, err = redis:rename(
                    cache_key .. "::" .. entity .. ":" .. k,
                    "ledge:entity:" .. new_entity_id .. ":" .. k
                )
                if not ok or ok == ngx.null then
                    ngx.say("Renaming ", k, " failed: ", err)
                end
            end

            -- Get the entity score
            local score, err = redis:zscore(
                cache_key .. "::entities",
                cache_key .. "::" .. entity
            )
            if not score or score == ngx.null then
                ngx.say("Unable to get entity score: ", err)
            end

            -- Add the entity to the entities set
            local res, err = redis:zadd(cache_key .. "::entities", score, new_entity_id)
            if not res or res == ngx.null then
                ngx.say("Unable to add to entities set: ", err)
            end

            local res, err = redis:zrem(
                cache_key .. "::entities",
                cache_key .. "::" .. entity
            )
            if not res or res == ngx.null then
                ngx.say("Unable to remove old entity from entities set: ", err)
            end

            --  Add the live entity pointer to the main hash, and delete the old pointer
            local ok, err = redis:hset(cache_key .. "::main", "entity", new_entity_id)
            if not ok or ok == ngx.null then
                ngx.say("Setting entity id failed: ", err)
            else
                local ok, err = redis:del(cache_key .. "::key")
                if not ok or ok == ngx.null then
                    ngx.say("Could not delete key: ", err)
                end
            end

            -- Add the memused to the main hash, and delete the old key
            local ok, err = redis:hset(cache_key .. "::main", "memused", memused)
            if not ok or ok == ngx.null then
                ngx.say("Setting memused failed: ", err)
            else
                local ok, err = redis:del(cache_key .. "::memused")
                if not ok or ok == ngx.null then
                    ngx.say("Could not delete memused: ", err)
                end
            end


            -- TODO:
            --  - Entities set needs the new ID, not the old key
            --  - Old entities need to be cleaned up
            --  - What happens if cache is updated before the script runs?

        end
    end

    local cursor = tonumber(res[1])
    if cursor > 0 then
        -- If we have a valid cursor, recurse to move on.
        return scan(cursor, redis)
    end

    ngx.say("\nComplete.")
    return true
end


local redis, err = redis_connector:connect{ url = "redis://127.0.0.1:6379/0" }
if not redis then
    ngx.say(err)
    return
end

ngx.say("Migrating Ledge data structure from v1.26 to v1.27")
scan(0, redis)
