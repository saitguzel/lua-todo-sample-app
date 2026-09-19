-- 004_rbac: rol-sayfa izin matrisi tablosu
-- Her rol × sayfa kombinasyonu için tek satır.
return {
  version = 4,
  name = "rbac",
  up = {
    [[CREATE TABLE role_page_permissions (
      role user_role NOT NULL,
      page_key VARCHAR(100) NOT NULL,
      can_access BOOLEAN NOT NULL DEFAULT false,
      PRIMARY KEY (role, page_key)
    )]],
  },
  down = {
    [[DROP TABLE IF EXISTS role_page_permissions]],
  },
}
