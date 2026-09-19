-- F14: Giriş ekranı. Shared şema ile doğrular; hatalı girişte e-posta varlığını ifşa etmez.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local storage = require("storage")
local validation = require("todo_shared.validation")
local protocol = require("todo_shared.protocol")

local _M = {}
_M.title = "Giriş"
_M.layout = false
_M.public = true

function _M.render(state, dispatch)
  local errors = (state.ui.form_errors or {}).login or {}
  local busy = state.ui.busy.login or false

  return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
    dom.form({
      class = "w-full max-w-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] shadow-[var(--shadow)] p-6",
      ["aria-labelledby"] = "login-title",
      onsubmit = function()
        -- form değerleri DOM'dan okunur (her tuşta global render olmasın); native submit glue.js'te engelli
        local email = dom.value("email") or ""
        local password = dom.value("password") or ""
        app.spawn(function() _M.submit(email, password, dispatch) end)
      end,
    },
      dom.h1({ id = "login-title", class = "text-xl font-bold mb-4" }, "Giriş yap"),
      -- genel hata bölgesi
      dom.div({ role = "alert", ["aria-live"] = "assertive", class = errors._ and "field-error mb-2" or "" },
        errors._ and errors._[1] or nil),
      dom.div({ class = "mb-3" },
        dom.label({ ["for"] = "email", class = "block text-sm font-medium mb-1" }, "E-posta"),
        dom.input({
          id = "email", name = "email", type = "email", autocomplete = "username", required = "required",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-describedby"] = errors.email and "email-err" or nil,
          ["aria-invalid"] = errors.email and "true" or nil,
        }),
        errors.email and dom.p({ id = "email-err", class = "field-error" }, errors.email[1]) or nil),
      dom.div({ class = "mb-4" },
        dom.label({ ["for"] = "password", class = "block text-sm font-medium mb-1" }, "Parola"),
        dom.input({
          id = "password", name = "password", type = "password", autocomplete = "current-password",
          required = "required", minlength = "8",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-describedby"] = errors.password and "password-err" or nil,
          ["aria-invalid"] = errors.password and "true" or nil,
        }),
        errors.password and dom.p({ id = "password-err", class = "field-error" }, errors.password[1]) or nil),
      dom.button({
        type = "submit",
        class = "w-full py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] font-medium",
        ["aria-busy"] = tostring(busy),
        disabled = busy and "disabled" or nil,
      }, busy and "Gönderiliyor…" or "Giriş yap"),
      dom.div({ class = "mt-4 text-center text-sm" },
        dom.a({ href = "#/forgot-password", class = "text-[var(--primary)] underline" }, "Şifremi unuttum"))))
end

function _M.submit(email, password, dispatch)
  dispatch({ type = "LOGIN_REQUESTED" })

  -- shared şema (F1) — frontend hatası = backend hatası
  local clean, errs = validation.validate(validation.schemas.login, { email = email, password = password })
  if not clean then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "login", errors = errs })
    app.dispatch({ type = "BUSY_SET", key = "login", value = false })
    -- ilk hatalı alana focus (a11y)
    local first = errs.email and "email" or (errs.password and "password" or nil)
    if first then dom.focus(first) end
    return
  end

  local data, err = api.post("/auth/login", clean)
  app.dispatch({ type = "BUSY_SET", key = "login", value = false })

  if err then
    local msg
    if err.code == "INVALID_CREDENTIALS" then
      msg = "E-posta veya parola hatalı" -- ayrım YOK (00 §5)
    elseif err.code == "RATE_LIMITED" then
      msg = err.retry_after
        and ("Çok fazla deneme. " .. math.ceil(err.retry_after) .. " saniye sonra tekrar deneyin.")
        or "Çok fazla deneme. Lütfen bir süre sonra tekrar deneyin."
    elseif err.code == "ACCOUNT_DISABLED" then
      msg = "Hesabınız pasif. Yöneticiye başvurun."
    elseif err.code == "NETWORK_ERROR" then
      msg = "Sunucuya ulaşılamadı"
    else
      msg = protocol.message(err.code)
    end
    app.dispatch({ type = "FORM_ERRORS_SET", form = "login", errors = { _ = { msg } } })
    -- parola temizlenir, e-posta korunur; odak parola alanına
    dom.set_value("password", "")
    dom.focus("password")
    return
  end

  -- token'ları sakla (fetch.lua configure'daki set_tokens zaten auth yazmıyor; login'de burada yazılır)
  if data and data.access_token then
    storage.set("auth", { access_token = data.access_token, refresh_token = data.refresh_token })
  end

  app.dispatch({ type = "LOGIN_SUCCEEDED", user = data.user, permissions = data.permissions or {} })

  -- next yalnızca #/ ile başlıyorsa kabul (open redirect koruması); login geçmişte kalmaz
  local st = app.get_state()
  local next_hash = st.route and st.route.query and router.safe_next(st.route.query.next)
  router.navigate(next_hash or "#/", { replace = true })
end

return _M
