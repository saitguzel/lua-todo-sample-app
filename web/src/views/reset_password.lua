-- F14: Şifre sıfırlama. Token URL'den okunup hemen history.replaceState ile silinir;
-- storage'a yazılmaz. Frontend eşleşme kontrolü + shared password şeması.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local validation = require("todo_shared.validation")
local protocol = require("todo_shared.protocol")

local _M = {}
_M.title = "Yeni parola"
_M.layout = false
_M.public = true

local function token_valid(token)
  return type(token) == "string" and #token == 64 and token:match("^%x+$") ~= nil
end

-- Token URL'den okunduğu an modülde tutulur (storage'a yazılmaz), sonra adres çubuğundan silinir.
-- silent: route yeniden işlenmez, yoksa token'sız ROUTE_CHANGED ekranı "geçersiz"e çevirirdi.
local held_token = nil

function _M.enter(route)
  if route.query and route.query.token then
    held_token = route.query.token
    router.navigate("#/reset-password", { silent = true })
  end
end

function _M.render(state)
  local errors = (state.ui.form_errors or {}).reset or {}
  local done = state.ui.reset_done or false

  if done then
    return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
      dom.div({ class = "w-full max-w-sm text-center", role = "status" },
        dom.h1({ class = "text-xl font-bold mb-2" }, "Parolanız güncellendi"),
        dom.a({ href = "#/login", class = "text-[var(--primary)] underline" }, "Giriş yap")))
  end

  local token = held_token or (state.route and state.route.query and state.route.query.token)
  if not token_valid(token) then
    return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
      dom.div({ class = "w-full max-w-sm text-center" },
        dom.h1({ class = "text-xl font-bold mb-2" }, "Bağlantı geçersiz"),
        dom.p({ class = "text-[var(--fg-muted)] mb-4" },
          "Bu sıfırlama bağlantısı geçersiz veya eksik."),
        dom.a({ href = "#/forgot-password", class = "text-[var(--primary)] underline" }, "Yeni bağlantı iste")))
  end

  return dom.main({ class = "min-h-screen flex items-center justify-center p-4", id = "main", tabindex = "-1" },
    dom.form({
      class = "w-full max-w-sm bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-6 shadow-[var(--shadow)]",
      ["aria-labelledby"] = "reset-title",
      onsubmit = function()
        local p1 = dom.value("new-password") or ""
        local p2 = dom.value("new-password-confirm") or ""
        app.spawn(function() _M.submit(token, p1, p2) end)
      end,
    },
      dom.h1({ id = "reset-title", class = "text-xl font-bold mb-4" }, "Yeni parola belirleyin"),
      dom.div({ role = "alert", class = errors._ and "field-error mb-2" or "" },
        errors._ and errors._[1] or nil),
      dom.div({ class = "mb-3" },
        dom.label({ ["for"] = "new-password", class = "block text-sm font-medium mb-1" }, "Yeni parola"),
        dom.input({
          id = "new-password", type = "password", required = "required", minlength = "8",
          autocomplete = "new-password",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          oninput = function(e)
            -- basit güç göstergesi (aria-live="polite")
            local v = e.value or ""
            local score = 0
            if #v >= 8 then score = score + 1 end
            if v:match("%u") and v:match("%l") then score = score + 1 end
            if v:match("%d") then score = score + 1 end
            local label = ({ "Zayıf", "Orta", "İyi", "Güçlü" })[score + 1] or ""
            local el = js.dom.byId("pw-strength")
            if el then
              js.dom.setText(el, "Parola gücü: " .. label)
              js.dom.release(el)
            end
          end,
        }),
        dom.p({ id = "pw-strength", class = "text-xs text-[var(--fg-muted)] mt-1", ["aria-live"] = "polite" }, "")),
      dom.div({ class = "mb-4" },
        dom.label({ ["for"] = "new-password-confirm", class = "block text-sm font-medium mb-1" }, "Parolayı onayla"),
        dom.input({
          id = "new-password-confirm", type = "password", required = "required", minlength = "8",
          autocomplete = "new-password",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
        }),
        errors.new_password and dom.p({ class = "field-error" }, errors.new_password[1]) or nil),
      dom.button({
        type = "submit",
        class = "w-full py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] font-medium",
      }, "Parolayı güncelle")))
end

function _M.submit(token, password, confirm)
  -- yalnızca UI kuralı: iki alan eşit mi
  if password ~= confirm then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "reset", errors = { _ = { "Parolalar eşleşmiyor" } } })
    dom.focus("new-password-confirm")
    return
  end

  local clean, errs = validation.validate(validation.schemas.reset_password, { token = token, new_password = password })
  if not clean then
    app.dispatch({ type = "FORM_ERRORS_SET", form = "reset", errors = errs })
    dom.focus("new-password")
    return
  end

  local _, err = api.post("/auth/reset-password", clean)
  if err then
    if err.code == "RESET_TOKEN_INVALID" then
      app.dispatch({ type = "FORM_ERRORS_SET", form = "reset",
        errors = { _ = { "Bağlantının süresi dolmuş veya kullanılmış" } } })
    else
      app.dispatch({ type = "FORM_ERRORS_SET", form = "reset", errors = errs or { _ = { protocol.message(err.code) } } })
    end
    return
  end

  held_token = nil -- tek kullanımlık
  app.dispatch({ type = "RESET_DONE" })
  app.toast("success", "Parolanız güncellendi")
  js.timer.after(1200, function() router.navigate("#/login") end)
end

return _M
