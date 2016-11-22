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


function delete(redis, cache_key, entities)
    redis:multi()
    -- Entities list is intact, so delete them too
    for _, entity in ipairs(entities) do
        delete_entity(redis, cache_key .. "::entities", entity)
    end

    local keys = {
        cache_key .. "::key",
        cache_key .. "::memused",
        cache_key .. "::entities",
    }
    redis:del(unpack(keys))
    return redis:exec()
end


function delete_entity(redis, set, entity)
    local keys = {
        entity,
        entity .. ":reval_req_headers",
        entity .. ":reval_params",
        entity .. ":headers",
        entity .. ":body",
        entity .. ":body_esi",
    }
    local res, err = redis:del(unpack(keys))

    -- Remove from the entities set
    local res, err = redis:zrem(set, entity)
end


function delete_old_entities(redis, set, members, current_entity)
    for _, entity in ipairs(members) do
        if entity ~= current_entity then
            delete_entity(redis, set, entity)
        end
    end
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
            local skip = false

            local entity = redis:get(cache_key .. "::key")
            if entity == ngx.null then entity = nil end -- prevent concatentation error
            local memused = redis:get(cache_key .. "::memused")
            local score = redis:zscore(cache_key .. "::entities", cache_key .. "::" .. (entity or ""))
            local entity_count = redis:zcard(cache_key .. "::entities")
            local entity_members = redis:zrange(cache_key .. "::entities", 0, -1)

            for _, val in ipairs({ entity, memused, score, entity_count, entity_members }) do
                if not val or val == ngx.null then
                    -- If we're missing something we need (likely evicted) -- delete this key
                    if delete(redis, cache_key, entity_members) then
                        keys_deleted = keys_deleted + 1
                    else
                        keys_failed = keys_failed + 1
                    end
                    skip = true
                end
            end

            -- Watch the main key - if it gets created by real traffic from here on in then
            -- the transaction will simply fail.
            local res = redis:watch(cache_key .. "::main")

            -- Find out if real traffic already created this cache entry
            local new_entity = redis:hget(cache_key .. "::main", "entity")
            if new_entity and new_entity ~= ngx.null then
                -- The old entities refs will still exist, so clean them up
                delete_old_entities(redis, cache_key .. "::entities", entity_members, new_entity)
                keys_processed = keys_processed + 1
                skip = true
            end

            if not skip then
                -- Start transaction
                redis:multi()

                -- Move main entity to main key
                local ok, err = redis:rename(cache_key .. "::" .. entity, cache_key .. "::main")

                -- Rename headers etc
                for _, k in ipairs({ "headers", "reval_req_headers", "reval_params" }) do
                    local ok, err = redis:rename(
                        cache_key .. "::" .. entity .. ":" .. k,
                        cache_key .. "::" .. k
                    )
                end

                -- Create a new entity id and rename the live entity to it
                local new_entity_id = random_hex(32)
                for _, k in ipairs({ "body", "body_esi" }) do
                    local ok, err = redis:rename(
                        cache_key .. "::" .. entity .. ":" .. k,
                        "ledge:entity:" .. new_entity_id .. ":" .. k
                    )
                end

                -- Add the entity to the entities set
                local res, err = redis:zadd(cache_key .. "::entities", score, new_entity_id)

                -- Remove the old form
                local res, err = redis:zrem(
                    cache_key .. "::entities",
                    cache_key .. "::" .. entity
                )

                --  Add the live entity pointer to the main hash, and delete the old pointer
                local ok, err = redis:hset(cache_key .. "::main", "entity", new_entity_id)
                local ok, err = redis:del(cache_key .. "::key")

                -- Add the memused to the main hash, and delete the old key
                local ok, err = redis:hset(cache_key .. "::main", "memused", memused)
                local ok, err = redis:del(cache_key .. "::memused")

                -- Delete entities scheduled for GC but will fail on new codebase
                delete_old_entities(redis, cache_key .. "::entities", entity_members, new_entity_id)

                local res, err = redis:exec()
                if not res or res == ngx.null then
                    ngx.say("transaction failed")
                    -- Something went wrong, lets try and delete this cache entry
                    if delete(redis, cache_key, entity_members) then
                        keys_deleted = keys_deleted + 1
                    else
                        keys_failed = keys_failed + 1
                    end
                else
                    keys_processed = keys_processed + 1
                end
            end
        end
    end

    local cursor = tonumber(res[1])
    if cursor > 0 then
        -- If we have a valid cursor, recurse to move on.
        return scan(cursor, redis)
    end

    return true
end

local dsn = arg[1]
if not dsn then
    ngx.say("Please provide a Redis Connector DSN as the first argument, in the form: redis://[PASSWORD@]HOST:PORT/DB")
else
    local redis, err = redis_connector:connect{ url = dsn }
    if not redis then
        ngx.say("Could not connect to Redis with DSN: ", dsn, " - ", err)
        return
    end

    keys_processed = 0
    keys_deleted = 0
    keys_failed = 0

    ngx.say("Migrating Ledge data structure from v1.26 to v1.27\n")

    local res, err = scan(0, redis)
    if not res or res == ngx.null then
        ngx.say("Faied to scan keyspace: ", err)
    else
        ngx.say("> ", keys_processed .. " cache entries successfully updated")
        ngx.say("> ", keys_deleted .. " incomplete / broken cache entries cleaned up")
        ngx.say("> ", keys_failed .. " failures\n")
    end
end
