-- Backend ve frontend'in paylaştığı enum'lar ve RBAC sayfa anahtarları.
-- Değerler veritabanı ENUM'ları (001/002 migration) ile birebir aynı olmalıdır.
local _M = {}

_M.ROLES = { "admin", "todouser" }
_M.TODO_STATUS = { "pending", "in_progress", "completed" }
_M.TODO_PRIORITY = { "low", "medium", "high" }

-- Sıra UI'daki (RBAC matrisi) sütun sırasıdır
_M.PAGES = {
  "dashboard", "todos.list", "todos.create", "todos.edit",
  "users.list", "users.create", "rbac.matrix", "audit.logs", "settings",
}

-- Sayfa görünen adları ve grupları (GET /rbac/pages, frontend menüsü, RBAC matris başlıkları)
_M.PAGE_META = {
  dashboard = { label = "Gösterge Paneli", group = "genel" },
  ["todos.list"] = { label = "Görev Listesi", group = "todos" },
  ["todos.create"] = { label = "Görev Oluşturma", group = "todos" },
  ["todos.edit"] = { label = "Görev Düzenleme", group = "todos" },
  ["users.list"] = { label = "Kullanıcı Listesi", group = "admin" },
  ["users.create"] = { label = "Kullanıcı Yönetimi", group = "admin" },
  ["rbac.matrix"] = { label = "Yetki Matrisi", group = "admin" },
  ["audit.logs"] = { label = "Denetim Kayıtları", group = "admin" },
  settings = { label = "Ayarlar", group = "admin" },
}

-- Varsayılan izinler (seed ve "sıfırla" için); 00-genel-bakis §7
_M.DEFAULT_PERMISSIONS = {
  admin = { ["*"] = true },
  todouser = { dashboard = true, ["todos.list"] = true,
               ["todos.create"] = true, ["todos.edit"] = true },
}

-- Değiştirilemez hücreler: { role, page_key }
_M.LOCKED_PERMISSIONS = { { role = "admin", page_key = "rbac.matrix" } }

-- Audit olay adları (00-genel-bakis §8 ile birebir, aynı sıra); audit filtre select'i ve spec enum'u için
_M.AUDIT_ACTIONS = {
  "auth.login.success", "auth.login.failure", "auth.logout", "auth.token.refresh",
  "auth.password.reset.request", "auth.password.reset.success",
  "todo.create", "todo.update", "todo.delete",
  "user.create", "user.update", "user.delete",
  "rbac.matrix.update", "access.denied",
}

-- Dizi → set dönüşümü (O(1) üyelik kontrolü için modül yüklenirken bir kez)
local function to_set(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

_M.ROLE_SET = to_set(_M.ROLES)
_M.STATUS_SET = to_set(_M.TODO_STATUS)
_M.PRIORITY_SET = to_set(_M.TODO_PRIORITY)
_M.PAGE_SET = to_set(_M.PAGES)

local audit_set = to_set(_M.AUDIT_ACTIONS)
_M.AUDIT_SET = audit_set

function _M.is_member(set, value)
  return set[value] == true
end

-- Rol + sayfa için varsayılan izin
function _M.default_permission(role, page_key)
  local perm = _M.DEFAULT_PERMISSIONS[role]
  if not perm then return false end
  if perm["*"] then return true end
  return perm[page_key] == true
end

-- ROLES × PAGES varsayılan matrisi; PUT /rbac/matrix gövdesi (schemas.rbac_matrix) şeklinde
function _M.default_matrix()
  local permissions = {}
  for _, role in ipairs(_M.ROLES) do
    for _, page in ipairs(_M.PAGES) do
      permissions[#permissions + 1] = {
        role = role,
        page_key = page,
        can_access = _M.default_permission(role, page),
      }
    end
  end
  return { permissions = permissions }
end

function _M.is_locked(role, page_key)
  for _, entry in ipairs(_M.LOCKED_PERMISSIONS) do
    if entry.role == role and entry.page_key == page_key then
      return true
    end
  end
  return false
end

return _M
