-- F14: Şifremi unuttum. API her durumda 202 döner (00 §5); ekran da tek mesaj gösterir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local validation = require("todo_shared.validation")

local _M = {}
_M.title = "Şifremi unuttum"
_M.layout = false
_M.public = true

function _M.render(state, dispatch)
  local errors = (state.ui.form_errors or {}).forgot or {}
  local sent = state.ui.forgot_sent or false

  if sent then
    -- Başarı mesajı role="status" bölgesinde; focus mesaja taşınır (a11y)
    return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
      dom.div({ class = "w-full max-w-sm text-center" },
        dom.div({ role = "status", tabindex = "-1", id = "forgot-status", class = "bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-6" },
          dom.h1({ class = "text-xl font-bold mb-2" }, "Bağlantı gönderildi"),
          dom.p({ class = "text-[var(--fg-muted)]" },
            "Bu e-posta sistemde kayıtlıysa birkaç dakika içinde sıfırlama bağlantısı gönderilecek.")),
        dom.p({ class = "mt-4 text-sm" },
          dom.a({ href = "#/login", class = "text-[var(--primary)] underline" }, "Girişe dön"))))
  end

  return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
    dom.form({
      class = "w-full max-w-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] shadow-[var(--shadow)] p-6",
      ["aria-labelledby"] = "forgot-title",
      onsubmit = function()
        local email = dom.value("forgot-email") or ""
        app.spawn(function() _M.submit(email) end)
      end,
    },
      dom.h1({ id = "forgot-title", class = "text-xl font-bold mb-4" }, "Şifremi unuttum"),
      dom.p({ class = "text-sm text-[var(--fg-muted)] mb-4" },
        "E-posta adresinizi girin; sıfırlama bağlantısı gönderilsin."),
      dom.div({ role = "alert", class = errors._ and "field-error mb-2" or "" },
        errors._ and errors._[1] or nil),
      dom.div({ class = "mb-4" },
        dom.label({ ["for"] = "forgot-email", class = "block text-sm font-medium mb-1" }, "E-posta"),
        dom.input({
          id = "forgot-email", type = "email", required = "required", autocomplete = "username",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-invalid"] = errors.email and "true" or nil,
          ["aria-describedby"] = errors.email and "forgot-email-err" or nil,
        }),
        errors.email and dom.p({ id = "forgot-email-err", class = "field-error" }, errors.email[1]) or nil),
      dom.button({
        type = "submit",
        class = "w-full py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] font-medium",
      }, "Sıfırlama bağlantısı gönder"),
      dom.p({ class = "mt-4 text-center text-sm" },
        dom.a({ href = "#/login", class = "text-[var(--primary)] underline" }, "Girişe dön"))))
end

function _M.submit(email)
  local clean, errs = validation.validate(validation.schemas.forgot_password, { email = email })
  if not clean then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "forgot", errors = errs })
    dom.focus("forgot-email")
    return
  end

  local _, err = api.post("/auth/forgot-password", clean)
  if err and err.code == "RATE_LIMITED" then
    app.toast("error", "Çok fazla deneme. Lütfen bir süre sonra tekrar deneyin.")
    return
  end
  -- diğer hatalar → aynı başarı mesajı (sızıntı yok)
  app.dispatch({ type = "FORGOT_SENT" })
  js.timer.after(50, function() dom.focus("forgot-status") end) -- render sonrası mesaja odak
end

return _M
