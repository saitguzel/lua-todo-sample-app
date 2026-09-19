-- 003_audit_logs: denetim kaydı tablosu ve indeksleri
-- Audit olayları JSONB alanlarında saklanır.
return {
  version = 3,
  name = "audit_logs",
  up = {
    [[CREATE TABLE audit_logs (
      id BIGSERIAL PRIMARY KEY,
      user_id UUID REFERENCES users(id) ON DELETE SET NULL,
      user_email VARCHAR(255),
      action VARCHAR(100) NOT NULL,
      entity_type VARCHAR(50),
      entity_id VARCHAR(100),
      old_value JSONB,
      new_value JSONB,
      ip_address INET,
      user_agent VARCHAR(512),
      status VARCHAR(20) DEFAULT 'success',
      error_message TEXT,
      created_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX idx_audit_created ON audit_logs(created_at DESC)]],
    [[CREATE INDEX idx_audit_user ON audit_logs(user_id)]],
    [[CREATE INDEX idx_audit_action ON audit_logs(action, created_at DESC)]],
  },
  down = {
    [[DROP TABLE IF EXISTS audit_logs]],
  },
}
