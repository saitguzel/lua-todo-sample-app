-- 006_triggers: updated_at otomatik güncelleme tetikleyicileri
-- set_updated_at() fonksiyonu her UPDATE öncesi çalışır.
return {
  version = 6,
  name = "triggers",
  up = {
    [[CREATE OR REPLACE FUNCTION set_updated_at()
      RETURNS TRIGGER AS $$
      BEGIN
        NEW.updated_at = now();
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql]],
    [[CREATE TRIGGER trg_users_updated_at
      BEFORE UPDATE ON users
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
    [[CREATE TRIGGER trg_todos_updated_at
      BEFORE UPDATE ON todos
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
  },
  down = {
    [[DROP TRIGGER IF EXISTS trg_todos_updated_at ON todos]],
    [[DROP TRIGGER IF EXISTS trg_users_updated_at ON users]],
    [[DROP FUNCTION IF EXISTS set_updated_at()]],
  },
}
