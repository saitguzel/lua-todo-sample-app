-- Kriptografik rastgelelik: resty.random (OpenSSL RAND_bytes, strong)
-- UUID v4 ve token üretimi, math.random asla kullanılmaz.
local resty_random = require("resty.random")
local resty_string = require("resty.string")

local _M = {}

function _M.bytes(n)
  local b = resty_random.bytes(n, true)
  if not b then error("CSPRNG basarisiz", 0) end
  return b
end

function _M.hex(n)
  return resty_string.to_hex(_M.bytes(n))
end

function _M.uuid4()
  local b = { string.byte(_M.bytes(16), 1, 16) }
  -- bit kütüphanesi LuaJIT
  local bit = require("bit")
  b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
  b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
  local parts = {}
  for i = 1, 16 do parts[i] = string.format("%02x", b[i]) end
  local h = table.concat(parts)
  return h:sub(1, 8) .. "-" .. h:sub(9, 12) .. "-" .. h:sub(13, 16) .. "-" .. h:sub(17, 20) .. "-" .. h:sub(21, 32)
end

function _M.token()
  return _M.hex(32)
end

return _M
