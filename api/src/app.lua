-- Lapis uygulama giris noktasi: route'lari router'dan kaydeder
-- Lapis'in kendi renkli istek/SQL logu kapalı: erişim logunu middleware.logger JSON olarak yazar
require("lapis.config").config({ "development", "test", "production" }, {
  logging = { requests = false, queries = false },
})
local lapis = require("lapis")
local router = require("router")
local errors = require("middleware.error_handler")

local app = lapis.Application()
app.layout = false

router.register(app)

-- 404: zincir dışında kalır; req_id ve X-Request-Id için logger çalıştırılır
app.handle_404 = function(self)
  require("middleware.logger").handle(self)
  return errors.respond(errors.new("NOT_FOUND", "Kaynak bulunamadi"))
end

app.handle_error = function(_, err, trace)
  return errors.on_unhandled(err, trace)
end

return app
