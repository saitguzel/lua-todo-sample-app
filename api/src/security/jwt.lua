-- HS256 JWT uretme ve dogrulama: sign_access, sign_refresh, verify, sha256_hex
-- Payload: sub,user_id,email,role,iat,exp,jti,typ,iss
local resty_jwt = require("resty.jwt")
local config = require("config")
local random = require("security.random")

local _M = {}
local resty_sha256 = require("resty.sha256")
local resty_str = require("resty.string")

local function sign(user, typ, ttl)
  local c = config.get().jwt
  local now = ngx.time()
  local payload = {
    sub = user.id,
    user_id = user.id,
    email = user.email,
    role = user.role,
    iat = now,
    exp = now + ttl,
    jti = random.uuid4(),
    typ = typ,
    iss = c.issuer,
  }
  local token = resty_jwt:sign(c.secret, { header = { typ = "JWT", alg = "HS256" }, payload = payload })
  return token, payload
end

function _M.sign_access(user)
  return sign(user, "access", config.get().jwt.access_ttl)
end

function _M.sign_refresh(user)
  return sign(user, "refresh", config.get().jwt.refresh_ttl)
end

function _M.verify(token, expected_typ)
  if type(token) ~= "string" or #token > 4096 then return nil, "UNAUTHORIZED" end
  local c = config.get().jwt
  if not c or not c.secret then return nil, "UNAUTHORIZED" end
  -- pcall ile koruma, lua-resty-jwt hata firlatabilir
  local obj
  local ok, res = pcall(function()
    return resty_jwt:verify(c.secret, token)
  end)
  if not ok or not res then return nil, "UNAUTHORIZED" end
  obj = res
  if not obj.verified then
    local reason = obj.reason or ""
    if reason:find("expired") then return nil, "TOKEN_EXPIRED" end
    return nil, "UNAUTHORIZED"
  end
  if obj.header and obj.header.alg ~= "HS256" then return nil, "UNAUTHORIZED" end
  local payload = obj.payload
  if not payload then return nil, "UNAUTHORIZED" end
  if payload.iss ~= c.issuer then return nil, "UNAUTHORIZED" end
  if expected_typ and payload.typ ~= expected_typ then return nil, "UNAUTHORIZED" end
  if not payload.jti or not payload.user_id then return nil, "UNAUTHORIZED" end
  if payload.exp and payload.exp < ngx.time() then return nil, "TOKEN_EXPIRED" end
  return payload
end

function _M.remaining_ttl(payload)
  return math.max((payload.exp or 0) - ngx.time(), 1)
end

function _M.sha256_hex(s)
  local sha = resty_sha256:new()
  sha:update(s)
  local digest = sha:final()
  return resty_str.to_hex(digest)
end

return _M
