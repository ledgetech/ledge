local setmetatable, tonumber, ipairs, type =
    setmetatable, tonumber, ipairs, type

local str_match = string.match
local str_sub = string.sub
local str_randomhex = require("ledge.util").string.randomhex
local str_split = require("ledge.util").string.split

local tbl_insert = table.insert
local tbl_sort = table.sort
local tbl_remove = table.remove
local tbl_concat = table.concat

local ngx_re_match = ngx.re.match
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

local get_header_token = require("ledge.header_util").get_header_token

local co_yield = coroutine.yield
local co_wrap = require("ledge.util").coroutine.wrap

local get_fixed_field_metatable_proxy =
    require("ledge.util").mt.get_fixed_field_metatable_proxy

local ngx_req_get_headers = ngx.req.get_headers
local ngx_RANGE_NOT_SATISFIABLE = 416
local ngx_PARTIAL_CONTENT = 206


local _M = {
    _VERSION = "2.3.0",
}


function _M.new()
    return setmetatable({
        ranges = {},
        boundary_end = "",
        boundary = "",
    }, get_fixed_field_metatable_proxy(_M))
end


-- returns a table of ranges, or nil
--
-- e.g.
-- {
--      { from = 0, to = 99 },
--      { from = 100, to = 199 },
-- }
local function req_byte_ranges()
    local bytes = get_header_token(ngx_req_get_headers().range, "bytes")
    local ranges = nil

    if bytes then
        ranges = str_split(bytes, ",")
        if not ranges then ranges = { bytes } end
        for i,r in ipairs(ranges) do
            local from, to = str_match(r, "(%d*)%-(%d*)")
            ranges[i] = { from = tonumber(from), to = tonumber(to) }
        end
    end

    return ranges
end
_M.req_byte_ranges = req_byte_ranges


local function sort_byte_ranges(first, second)
    if not first.from or not second.from then
        return nil, "Attempt to compare invalid byteranges"
    end
    return first.from <= second.from
end


local function parse_content_range(content_range)
    local m, err = ngx_re_match(
        content_range,
        [[bytes\s+(\d+|\*)-(\d+|\*)/(\d+)]],
        "oj"
    )
    if err then ngx_log(ngx_ERR, err) end

    if not m then
        return nil
    else
        return tonumber(m[1]), tonumber(m[2]), tonumber(m[3])
    end
end
_M.parse_content_range = parse_content_range


-- Modifies the response based on range request headers.
-- Returns the response and a flag, which if true indicates a partial response
-- should be expected, if false indicates the range could not be applied, and if
-- nil indicates no range was requested.
function _M.handle_range_request(self, res)
    local range_request = req_byte_ranges()

    if range_request and type(range_request) == "table" and res.size then
        -- Don't attempt range filtering on non 200 responses
        if res.status ~= 200 then
            return res, false
        end

        local ranges = {}

        for _,range in ipairs(range_request) do
            local range_satisfiable = true

            if not range.to and not range.from then
                range_satisfiable = false
            end

            -- A missing "to" means to the "end".
            if not range.to then
                range.to = res.size - 1
            end

            -- A missing "from" means "to" is an offset from the end.
            if not range.from then
                range.from = res.size - (range.to)
                range.to = res.size - 1

                if range.from < 0 then
                    range_satisfiable = false
                end
            end

            -- A "to" greater than size should be "end"
            if range.to > (res.size - 1) then
                range.to = res.size - 1
            end

            -- Check the range is satisfiable
            if range.from > range.to then
                range_satisfiable = false
            end

            if not range_satisfiable then
                -- We'll return 416
                res.status = ngx_RANGE_NOT_SATISFIABLE
                res.body_reader = res.empty_body_reader
                res.header.content_range = "bytes */" .. res.size

                return res, false
            else
                -- We'll need the content range header value
                -- for multipart boundaries: e.g. bytes 5-10/20
                range.header = "bytes " .. range.from ..
                                "-" .. range.to ..
                                "/" .. res.size
                tbl_insert(ranges, range)
            end
        end

        local numranges = #ranges
        if numranges > 1 then
            -- Sort ranges as we cannot serve unordered.
            tbl_sort(ranges, sort_byte_ranges)

            -- Coalesce overlapping ranges.
            for i = numranges,1,-1 do
                if i > 1 then
                    local current_range = ranges[i]
                    local previous_range = ranges[i - 1]

                    if current_range.from <= previous_range.to then
                        -- extend previous range to encompass this one
                        previous_range.to = current_range.to
                        previous_range.header = "bytes " ..
                                                previous_range.from ..
                                                "-" ..
                                                current_range.to ..
                                                "/" ..
                                                res.size
                        tbl_remove(ranges, i)
                    end
                end
            end
        end

        self.ranges = ranges

        if #ranges == 1 then
            -- We have a single range to serve.
            local range = ranges[1]

            local size = res.size

            res.status = ngx_PARTIAL_CONTENT
            ngx.header["Accept-Ranges"] = "bytes"
            res.header["Content-Range"] = "bytes " .. range.from ..
                                            "-" .. range.to ..
                                            "/" .. size

            return res, true
        else
            -- Generate boundary
            local boundary_string = str_randomhex(32)
            local boundary = {
                "",
                "--" .. boundary_string,
            }

            if res.header["Content-Type"] then
                tbl_insert(
                    boundary,
                    "Content-Type: " .. res.header["Content-Type"]
                )
            end

            self.boundary = tbl_concat(boundary, "\n")
            self.boundary_end = "\n--" .. boundary_string .. "--"

            res.status = ngx_PARTIAL_CONTENT
            -- TODO: No test coverage for these headers
            res.header["Accept-Ranges"] = "bytes"
            res.header["Content-Type"] = "multipart/byteranges; boundary=" ..
                                         boundary_string

            return res, true
        end
    end

    return res, nil
end


-- Filters the body reader, only yielding bytes specified in a range request.
function _M.get_range_request_filter(self, reader)
    local ranges = self.ranges
    local boundary_end = self.boundary_end
    local boundary = self.boundary

    if ranges then
        return co_wrap(function(buffer_size)
            local playhead = 0
            local num_ranges = #ranges

            while true do
                local chunk, err = reader(buffer_size)
                if err then ngx_log(ngx_ERR, err) end
                if not chunk then break end

                local chunklen = #chunk
                local nextplayhead = playhead + chunklen

                for _, range in ipairs(ranges) do
                    if range.from >= nextplayhead or range.to < playhead then -- luacheck: ignore 542
                        -- Skip over non matching ranges (this is
                        -- algorithmically simpler)
                    else
                        -- Yield the multipart byterange boundary if
                        -- required and only once per range.
                        if num_ranges > 1 and not range.boundary_printed then
                            co_yield(boundary)
                            co_yield("\nContent-Range: " .. range.header)
                            co_yield("\n\n")
                            range.boundary_printed = true
                        end

                        -- Trim range to within this chunk's context
                        local yield_from = range.from
                        local yield_to = range.to
                        if range.from < playhead then
                            yield_from = playhead
                        end
                        if range.to >= nextplayhead then
                            yield_to = nextplayhead - 1
                        end

                        -- Find relative points for the range within this chunk
                        local relative_yield_from = yield_from - playhead
                        local relative_yield_to = yield_to - playhead

                        -- Ranges are all 0 indexed, finally convert to 1 based
                        -- Lua indexes, and yield the range.
                        co_yield(
                            str_sub(
                                chunk,
                                relative_yield_from + 1,
                                relative_yield_to + 1
                            )
                        )
                    end
                end

                playhead = playhead + chunklen
            end

            -- Yield the multipart byterange end marker
            if num_ranges > 1 then
                co_yield(boundary_end)
            end
        end)
    end

    return reader
end


return _M
