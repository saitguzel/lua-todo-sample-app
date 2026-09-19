-- 007_cleanup_logs: temizlik işi meta-log tablosu
-- Günde bir satır, yılda 365 satır.
return {
  version = 7,
  name = "cleanup_logs",
  up = {
    [[CREATE TABLE cleanup_logs (
      id BIGSERIAL PRIMARY KEY,
      job_name VARCHAR(100) NOT NULL,
      table_name VARCHAR(100),
      deleted_count INTEGER DEFAULT 0,
      batch_count INTEGER DEFAULT 0,
      duration_ms INTEGER,
      status VARCHAR(20) DEFAULT 'success',
      error_message TEXT,
      created_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX idx_cleanup_created ON cleanup_logs(created_at DESC)]],
  },
  down = {
    [[DROP TABLE IF EXISTS cleanup_logs]],
  },
}
