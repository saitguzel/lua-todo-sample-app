-- 001_users: pgcrypto, user_role enum ve users tablosu
-- E-posta lower check, triggerlar 006'da eklenir.
return {
  version = 1,
  name = "users",
  up = {
    [[CREATE EXTENSION IF NOT EXISTS pgcrypto]],
    [[CREATE TYPE user_role AS ENUM ('admin', 'todouser')]],
    [[CREATE TABLE users (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      email VARCHAR(255) UNIQUE NOT NULL,
      password_hash VARCHAR(255) NOT NULL,
      full_name VARCHAR(255),
      role user_role NOT NULL DEFAULT 'todouser',
      is_active BOOLEAN DEFAULT true,
      last_login_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT now(),
      updated_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[ALTER TABLE users ADD CONSTRAINT users_email_lower CHECK (email = lower(email))]],
  },
  down = {
    [[DROP TABLE IF EXISTS users]],
    [[DROP TYPE IF EXISTS user_role]],
  },
}
