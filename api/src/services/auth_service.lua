-- Auth servis: login/refresh/logout/forgot/reset/me, rate limit, token rotasyonu
local config = require("config")
local jwt = require("security.jwt")
local password = require("security.password")
local random = require("security.random")
local user_repo = require("repositories.user_repo")
local user_model = require("models.user")
local errors = require("middleware.error_handler")
local query = require("db.query")
local rbac_service = require("services.rbac_service")

local _M = {}

-- Olmayan kullanıcıda da argon2 verify çalışsın (zamanlama kanalı olmasın); worker başına bir kez
local DUMMY_HASH = nil
local function ensure_dummy()
  if not DUMMY_HASH then
    DUMMY_HASH = assert(password.hash(random.hex(16)))
  end
  return DUMMY_HASH
end

local function rate_limited(ttl, msg)
  local secs = math.max(1, math.floor(ttl or 60))
  local e = errors.new("RATE_LIMITED", msg, { retry_after = secs })
  e.headers = { ["Retry-After"] = tostring(secs) }
  return e
end

local function rate_limit_key(ip, email)
  return "login:" .. (ip or "unknown") .. ":" .. (email or "")
end

function _M.revoke_jti(jti, exp)
  if not jti or not exp then return true end
  local ttl = exp - ngx.time()
  if ttl <= 0 then return true end
  local dict = ngx.shared.jwt_denylist
  if not dict then return true end
  local ok, err, forcible = dict:set("jti:" .. jti, 1, ttl)
  if not ok then ngx.log(ngx.ERR, "denylist set basarisiz: ", err) end
  if forcible then ngx.log(ngx.WARN, "jwt_denylist dolu, eski kayitlar atildi") end
  return ok
end

function _M.is_revoked(jti)
  if not jti then return false end
  local dict = ngx.shared.jwt_denylist
  if not dict then return false end
  return dict:get("jti:" .. jti) ~= nil
end

function _M.issue_tokens(user)
  local access, a_payload = jwt.sign_access(user)
  local refresh, r_payload = jwt.sign_refresh(user)
  local c = config.get()
  return {
    access_token = access,
    refresh_token = refresh,
    token_type = "Bearer",
    expires_in = c.jwt.access_ttl,
    refresh_expires_in = c.jwt.refresh_ttl,
    user = user_model.serialize(user),
    permissions = rbac_service.permissions_for(user.role),
    _a_payload = a_payload,
    _r_payload = r_payload,
  }
end

function _M.login(email, pwd)
  local audit_service = require("services.audit_service")
  local ip = ngx.ctx and ngx.ctx.audit and ngx.ctx.audit.ip or ngx.var.remote_addr
  local email_n = email and email:lower():match("^%s*(.-)%s*$") or ""
  -- rate limit
  local dict = ngx.shared.rate_limit
  if dict and config.get() then
    local key = rate_limit_key(ip, email_n)
    local cnt = dict:incr(key, 1, 0, 60)
    if cnt and cnt > config.get().login_rate_limit then
      audit_service.record("auth.login.failure", {
        entity_type = "user", status = "failure", user_email = email_n,
        new_value = { email = email_n, reason = "rate_limited" }, error_message = "rate_limited",
      })
      return nil, rate_limited(dict:ttl(key), "Cok fazla deneme, lutfen bekleyin")
    end
  end
  local user, uerr = user_repo.find_by_email(email_n)
  -- DB hatası "kullanıcı yok"a gömülmez (DB_UNAVAILABLE / INTERNAL_ERROR)
  if uerr then return nil, uerr end
  local hash = user and user.password_hash or ensure_dummy()
  local ok = password.verify(hash, pwd or "")
  if not user or not ok then
    audit_service.record("auth.login.failure", {
      entity_type = "user", status = "failure", user_email = email_n,
      user_id = user and user.id or nil,
      new_value = { email = email_n, reason = "invalid_credentials" },
      error_message = "invalid_credentials",
    })
    return nil, errors.new("INVALID_CREDENTIALS", "E-posta veya parola hatali")
  end
  if not user.is_active then
    audit_service.record("auth.login.failure", {
      entity_type = "user", user_id = user.id, user_email = user.email,
      status = "failure", new_value = { email = email_n, reason = "disabled" },
      error_message = "disabled",
    })
    return nil, errors.new("ACCOUNT_DISABLED", "Hesabiniz pasif durumda")
  end
  user_repo.touch_last_login(user.id)
  if dict then dict:delete(rate_limit_key(ip, email_n)) end
  -- needs_rehash
  if password.needs_rehash(user.password_hash) then
    local new_hash = password.hash(pwd)
    if new_hash then
      user_repo.update_password(user.id, new_hash)
    end
  end
  local tokens = _M.issue_tokens(user)
  audit_service.record("auth.login.success", {
    entity_type = "user", user_id = user.id, user_email = user.email,
    new_value = { email = user.email },
  })
  -- tokens icinde user ve permissions var, handler data olarak dondurur
  local result = {
    access_token = tokens.access_token,
    refresh_token = tokens.refresh_token,
    token_type = tokens.token_type,
    expires_in = tokens.expires_in,
    refresh_expires_in = tokens.refresh_expires_in,
    user = tokens.user,
    permissions = tokens.permissions,
  }
  return result, nil
end

function _M.refresh(refresh_token)
  local audit_service = require("services.audit_service")
  local claims, err = jwt.verify(refresh_token, "refresh")
  if not claims then
    local code = err == "TOKEN_EXPIRED" and "TOKEN_EXPIRED" or "UNAUTHORIZED"
    return nil, errors.new(code, "Gecersiz token")
  end
  if _M.is_revoked(claims.jti) then
    ngx.log(ngx.WARN, "revoked refresh tekrar kullanildi jti=", claims.jti)
    return nil, errors.new("TOKEN_REVOKED", "Token iptal edilmis")
  end
  local user, uerr = user_repo.find_by_id(claims.user_id)
  if uerr then return nil, uerr end
  if not user then return nil, errors.new("UNAUTHORIZED", "Kullanici bulunamadi") end
  if not user.is_active then return nil, errors.new("ACCOUNT_DISABLED", "Hesabiniz pasif durumda") end
  _M.revoke_jti(claims.jti, claims.exp)
  local tokens = _M.issue_tokens(user)
  audit_service.record("auth.token.refresh", { entity_type = "user", user_id = user.id, user_email = user.email })
  local result = {
    access_token = tokens.access_token,
    refresh_token = tokens.refresh_token,
    token_type = tokens.token_type,
    expires_in = tokens.expires_in,
    refresh_expires_in = tokens.refresh_expires_in,
    user = tokens.user,
    permissions = tokens.permissions,
  }
  return result, nil
end

function _M.logout(identity, refresh_token)
  local audit_service = require("services.audit_service")
  if identity and identity.jti and identity.exp then
    _M.revoke_jti(identity.jti, identity.exp)
  end
  if refresh_token and type(refresh_token) == "string" and #refresh_token > 0 then
    local claims = jwt.verify(refresh_token, "refresh")
    if claims and claims.user_id == identity.user_id then
      _M.revoke_jti(claims.jti, claims.exp)
    end
  end
  audit_service.record("auth.logout", { entity_type = "user", entity_id = identity.user_id })
  return true
end

function _M.forgot_password(email)
  local audit_service = require("services.audit_service")
  local ip = ngx.ctx and ngx.ctx.audit and ngx.ctx.audit.ip or ngx.var.remote_addr
  local dict = ngx.shared.rate_limit
  if dict then
    local key = "forgot:" .. (ip or "unknown")
    local cnt = dict:incr(key, 1, 0, 60)
    if cnt and cnt > (config.get() and config.get().login_rate_limit or 5) then
      return nil, rate_limited(dict:ttl(key), "Cok fazla deneme")
    end
  end
  local email_n = email:lower():match("^%s*(.-)%s*$")
  local user, uerr = user_repo.find_by_email(email_n)
  if uerr then return nil, uerr end
  audit_service.record("auth.password.reset.request", {
    entity_type = "user", user_id = user and user.id or nil, user_email = email_n,
    new_value = { email = email_n },
  })
  if user and user.is_active then
    local raw = random.hex(32)
    local hash = jwt.sha256_hex(raw)
    local ttl = config.get() and config.get().password_reset_ttl or 3600
    local saved, terr = query.with_transaction(function()
      local ok1, e1 = user_repo.reset_token_invalidate_all(user.id)
      if not ok1 then return nil, e1 end
      local ok2, e2 = user_repo.reset_token_create(user.id, hash, ttl)
      if not ok2 then return nil, e2 end
      return true
    end)
    -- token saklanamadıysa mail gönderilmez (çalışmayan link gitmesin); yanıt yine 202
    if not saved then
      ngx.log(ngx.ERR, "reset token saklanamadi: ", tostring(terr and terr.code), " req_id=", tostring(ngx.ctx.req_id))
      return nil, terr
    end
    local base = config.get() and config.get().app and config.get().app.web_base_url or "http://localhost:28000"
    local link = base .. "/#/reset-password?token=" .. raw
    -- timer ile mail
    local mail_mod = require("mail.smtp")
    local full_name = user.full_name or user.email
    local function send_mail(premature)
      if premature then return end
      local rendered = mail_mod.render_reset_mail(full_name, link, ttl)
      rendered.to = user.email
      local ok, err = mail_mod.send(rendered)
      if not ok then ngx.log(ngx.ERR, "mail gonderilemedi: ", err) end
    end
    local ok, err = ngx.timer.at(0, send_mail)
    if not ok then
      -- fallback sync
      ngx.log(ngx.ERR, "timer at basarisiz, sync mail denenecek: ", err)
      pcall(send_mail, false)
    end
  end
  return true
end

function _M.reset_password(token, new_password)
  local audit_service = require("services.audit_service")
  local hash = jwt.sha256_hex(token)
  local new_hash, herr = password.hash(new_password)
  if not new_hash then return nil, errors.new("VALIDATION_FAILED", herr) end
  local ok, err = query.with_transaction(function()
    local row, ferr = user_repo.reset_token_find_valid_for_update(hash)
    if ferr then return nil, ferr end
    if not row then
      return nil, errors.new("RESET_TOKEN_INVALID", "Gecersiz veya suresi dolmus baglanti")
    end
    local ok1, e1 = user_repo.update_password(row.user_id, new_hash)
    if not ok1 then return nil, e1 end
    local ok2, e2 = user_repo.reset_token_mark_used(row.id)
    if not ok2 then return nil, e2 end
    local ok3, e3 = user_repo.reset_token_invalidate_all(row.user_id)
    if not ok3 then return nil, e3 end
    return row
  end)
  if not ok then return nil, err end
  audit_service.record("auth.password.reset.success", { entity_type = "user", user_id = ok.user_id })
  return true
end

function _M.me(identity)
  local user, uerr = user_repo.find_by_id(identity.user_id)
  if uerr then return nil, uerr end
  if not user then return nil, errors.new("USER_NOT_FOUND", "Kullanici bulunamadi") end
  return user_model.serialize(user), nil
end

return _M
