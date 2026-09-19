-- 005_password_reset: parola sıfırlama token tablosu
-- Token hash SHA256 ile saklanır, ham token asla yazılmaz.
return {
  version = 5,
  name = "password_reset",
  up = {
    [[CREATE TABLE password_reset_tokens (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      token_hash VARCHAR(64) UNIQUE NOT NULL,
      expires_at TIMESTAMPTZ NOT NULL,
      used_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX idx_reset_user ON password_reset_tokens(user_id)]],
    [[CREATE INDEX idx_reset_expires ON password_reset_tokens(expires_at)]],
  },
  down = {
    [[DROP TABLE IF EXISTS password_reset_tokens]],
  },
}
