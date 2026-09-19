-- Sayfa bazli yetki kontrolu: rol/page izni yoksa 403 + access.denied audit
local rbac_service = require("services.rbac_service")
local errors = require("middleware.error_handler")

local _M = {}

function _M.requires(page_key)
  return function()
    local identity = ngx.ctx.identity
    -- kimlik yoksa (auth middleware atlanmış) yetki değil kimlik sorunu: 401
    if not identity then
      return errors.respond(errors.new("UNAUTHORIZED", "Kimlik dogrulama gerekli"))
    end
    if rbac_service.can(identity.role, page_key) then
      return nil
    end
    -- audit
    require("services.audit_service").record("access.denied", {
      entity_type = "page", entity_id = page_key, status = "failure",
      new_value = { page_key = page_key, method = ngx.req.get_method(), path = ngx.var.uri },
      error_message = "forbidden",
    })
    return errors.respond(errors.new("FORBIDDEN", "Bu islem icin yetkiniz yok", { page_key = page_key }))
  end
end

return _M
