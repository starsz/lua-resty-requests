-- Copyright (C) Alex Zhang

local cjson = require "cjson.safe"
local util = require "resty.requests.util"

local is_tab = util.is_tab
local new_tab = util.new_tab
local find = string.find
local insert = table.insert
local concat = table.concat
local tonumber = tonumber
local setmetatable = setmetatable

local _M = { _VERSION = "0.1" }
local mt = { __index = _M }

local DEFAULT_ITER_SIZE = 8192
local STATE = util.STATE


local function no_body(r)
    local status_code = r.status_code

    -- 1xx, 204 and 304
    if status_code < 200
       or status_code == 204
       or status_code == 304 then
        return true
    end

    -- HEAD
    if r.method == "HEAD" then
        return true
    end
end


local function process_headers(headers)
    for k, v in pairs(headers) do
        if is_tab(v) then
            headers[k] = concat(v, ",")
        end
    end

    return headers
end


local function iter_chunked(r, size)
    local chunk = r._chunk

    if chunk.leave then
        r._read_eof = true
        chunk.leave = false
        return ""
    end

    local adapter = r._adapter

    size = size or DEFAULT_ITER_SIZE

    adapter.state = STATE.RECV_BODY

    local t
    if size then
        t = new_tab(0, 4)
    end

    local reader = chunk.reader

    while true do
        if chunk.rest == 0 then
            local size, err = reader()
            if not size then
                return nil, err
            end

            -- just ignore the chunk-extensions
            local ext = size:find(";", nil, true)
            if ext then
                size = size:sub(1, ext - 1)
            end

            size = tonumber(size, 16)
            if not size then
                return nil, "invalid chunk header"
            end

            chunk.size = size
            chunk.rest = size
        end

        -- end
        if chunk.size == 0 then
            if not size then
                r._read_eof = true
                return ""
            end

            chunk.leave = true

            break
        end

        local read_size = size
        if not size or read_size > chunk.rest then
            read_size = chunk.rest
        end

        local data, err = adapter.sock:receive(read_size)
        if err then
            return data, err
        end

        if not size then
            chunk.rest = 0
        else
            size = size - read_size
            chunk.rest = chunk.rest - read_size
        end

        if chunk.rest == 0 then
            local dummy, err = reader()
            if dummy ~= "" then
                return nil, err or "invalid chunked data"
            end
        end

        if not size then
            return data
        end

        insert(t, data)
        if size == 0 then
            break
        end
    end

    return concat(t, "")
end


local function iter_plain(r, size)
    local rest = r._rest
    local adapter = r._adapter

    adapter.state = STATE.RECV_BODY

    if rest == 0 then
        r._read_eof = true
        return ""
    end

    size = size or DEFAULT_ITER_SIZE

    if rest and rest < size then
        size = rest
    end

    local data, err = adapter.sock:receive(size)
    if err then
        return data, err
    end

    r._rest = rest - #data

    return data
end


local function new(opts)
    local r = {
        url = opts.url,
        method = opts.method,
        status_line = opts.status_line,
        status_code = opts.status_code,
        http_version = opts.http_version,
        headers = opts.headers,
        request = opts.request,

        -- internal members
        _adapter = opts.adapter,
        _consumed = false,
        _chunk = nil,
        _rest = -1,
        _read_eof = false,
        _keepalive = false,
    }

    local chunk = r.headers["Transfer-Encoding"]
    if chunk and find(chunk, "chunked", nil, true) then
        r._chunk = {
            size = -1,
            rest = 0,
            leave = false,
            reader = r._adapter.sock:receiveuntil("\r\n"),
        }
    else
        r._rest = tonumber(r.headers["Content-Length"])
        if r._rest == 0 or no_body(r) then
            r._read_eof = true
        end
    end

    local connection = r.headers["Connnection"]
    if connection == "keep-alive" then
        r._keepalive = true
    end

    r.headers = process_headers(r.headers)

    return setmetatable(r, mt)
end


local function iter_content(r, size)
    if r._read_eof then
        return nil, "eof"
    end

    local adapter = r._adapter
    if adapter.state == STATE.CLOSE then
        return nil, "closed"
    end

    local data, err

    if r._chunk then
        data, err = iter_chunked(r, size)
    else
        data, err = iter_plain(r, size)
    end

    local error_filter = adapter.error_filter

    if err then
        if error_filter then
            error_filter(adapter.state, err)
        end

        adapter.state = STATE.CLOSE

        adapter:close(r._keepalive)

        return nil, err
    end

    return data
end


local function body(r)
    if r.consumed then
        return nil, "is consumed"
    end

    r.consumed = true

    local t = new_tab(8, 0)
    while true do
        local data, err = r:iter_content()
        if err then
            return nil, err
        end

        if data == "" then
            break
        end

        insert(t, data)
    end

    return concat(t, "")
end


local function json(r)
    local data, err = r:body()
    if not data then
        return nil, err
    end

    local content_type = r.headers["Content-Type"]
    if content_type ~= "application/json" then
        return nil, "not json"
    end

    return cjson.encode(data)
end


local function close(r)
    local adapter = r._adapter
    return adapter:close(r._keepalive)
end


_M.new = new
_M.close = close
_M.iter_content = iter_content
_M.body = body
_M.json = json

return _M
