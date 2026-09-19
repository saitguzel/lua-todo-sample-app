-- 002_todos: todo enumları ve todos tablosu
-- İndeksler ve title boş olamaz check constraint'i dahil.
return {
  version = 2,
  name = "todos",
  up = {
    [[CREATE TYPE todo_status AS ENUM ('pending', 'in_progress', 'completed')]],
    [[CREATE TYPE todo_priority AS ENUM ('low', 'medium', 'high')]],
    [[CREATE TABLE todos (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      title VARCHAR(255) NOT NULL,
      description TEXT,
      status todo_status NOT NULL DEFAULT 'pending',
      priority todo_priority NOT NULL DEFAULT 'medium',
      due_date TIMESTAMPTZ,
      tags TEXT[] DEFAULT '{}',
      completed_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ DEFAULT now(),
      updated_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX idx_todos_user_status ON todos(user_id, status)]],
    [[CREATE INDEX idx_todos_user_created ON todos(user_id, created_at DESC)]],
    [[CREATE INDEX idx_todos_due_date ON todos(due_date) WHERE status <> 'completed']],
    [[CREATE INDEX idx_todos_tags ON todos USING GIN (tags)]],
    [[ALTER TABLE todos ADD CONSTRAINT todos_title_not_blank CHECK (length(btrim(title)) > 0)]],
  },
  down = {
    [[DROP TABLE IF EXISTS todos]],
    [[DROP TYPE IF EXISTS todo_priority]],
    [[DROP TYPE IF EXISTS todo_status]],
  },
}
