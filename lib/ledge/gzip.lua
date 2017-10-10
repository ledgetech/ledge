local co_yield = coroutine.yield
local co_wrap = require("ledge.util").coroutine.wrap

local ngx_log = ngx.log
local ngx_ERR = ngx.ERR

local zlib = require("ffi-zlib")


local _M = {
    _VERSION = "2.0.4",
}


local zlib_output = function(data)
    co_yield(data)
end


local function get_gzip_decoder(reader)
    return co_wrap(function(buffer_size)
        local ok, err = zlib.inflateGzip(reader, zlib_output, buffer_size)
        if not ok then
            ngx_log(ngx_ERR, err)
        end

        -- zlib decides it is done when the stream is complete.
        -- Call reader() one more time to resume the next coroutine in the
        -- chain.
        reader(buffer_size)
    end)
end
_M.get_gzip_decoder = get_gzip_decoder


local function get_gzip_encoder(reader)
    return co_wrap(function(buffer_size)
        local ok, err = zlib.deflateGzip(reader, zlib_output, buffer_size)
        if not ok then
            ngx_log(ngx_ERR, err)
        end

        -- zlib decides it is done when the stream is complete.
        -- Call reader() one more time to resume the next coroutine in the
        -- chain
        reader(buffer_size)
    end)
end
_M.get_gzip_encoder = get_gzip_encoder


return _M
