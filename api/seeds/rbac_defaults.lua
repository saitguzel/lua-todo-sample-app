-- rbac_defaults: varsayılan RBAC matrisi seed'i
-- Her rol × sayfa için tek satır, mevcut satır korunur.
local types = require("todo_shared.types")

return {
  name = "rbac_defaults",
  run = function(q)
    for _, role in ipairs(types.ROLES) do
      for _, page in ipairs(types.PAGES) do
        q([[INSERT INTO role_page_permissions (role, page_key, can_access)
            VALUES ($1::user_role, $2, $3)
            ON CONFLICT (role, page_key) DO NOTHING]],
          role, page, types.default_permission(role, page))
      end
    end
  end,
}
