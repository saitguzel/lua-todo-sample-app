-- Argon2id parola hashleme: hash, verify, needs_rehash, dummy_verify
-- Her hash 16 byte salt ile, encoded format $argon2id$v=19$m=4096,t=3,p=1$...
local argon2 = require("argon2")
local config = require("config")
local random = require("security.random")

local _M = {}

local SALT_BYTES = 16
local DUMMY_HASH = nil

local function options()
  local c = config.get() and config.get().argon2 or { t_cost = 3, m_cost = 12, parallelism = 1 }
  return {
    variant = argon2.variants.argon2_id,
    t_cost = c.t_cost,
    m_cost = 2 ^ c.m_cost,
    parallelism = c.parallelism,
    hash_len = 32,
  }
end

function _M.hash(plain)
  if type(plain) ~= "string" or #plain == 0 or #plain > 1024 then
    return nil, "gecersiz parola girdisi"
  end
  local encoded, err = argon2.hash_encoded(plain, random.bytes(SALT_BYTES), options())
  if not encoded then return nil, err end
  -- lua-argon2 3.0.1 C tamponunun sonundaki NUL'u da döndürür; Postgres TEXT bunu reddeder
  return (encoded:gsub("%z+$", ""))
end

function _M.verify(encoded, plain)
  if type(encoded) ~= "string" or type(plain) ~= "string" then return false end
  local ok, err = argon2.verify(encoded, plain)
  if err then
    ngx.log(ngx.WARN, "argon2 verify hatasi: ", err)
  end
  return ok == true
end

function _M.needs_rehash(encoded)
  if type(encoded) ~= "string" then return true end
  local m_s, t_s, p_s = encoded:match("m=(%d+),t=(%d+),p=(%d+)")
  if not m_s then return false end
  local m = tonumber(m_s)
  local t = tonumber(t_s)
  local p = tonumber(p_s)
  local c = config.get() and config.get().argon2 or { t_cost = 3, m_cost = 12, parallelism = 1 }
  local expected_m = 2 ^ c.m_cost
  if m < expected_m then return true end
  if t < c.t_cost then return true end
  if p ~= c.parallelism then return true end
  return false
end

function _M.dummy_verify(plain)
  if not DUMMY_HASH then
    local h, _ = _M.hash("dummy-password-for-timing")
    DUMMY_HASH = h or "$argon2id$v=19$m=4096,t=3,p=1$dGVzdA$hash"
  end
  _M.verify(DUMMY_HASH, plain)
  return false
end

return _M
