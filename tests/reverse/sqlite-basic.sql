CREATE TABLE "todo" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "title" TEXT NOT NULL,
  "done" INTEGER NOT NULL DEFAULT 0,
  "created_at" TEXT NOT NULL DEFAULT (datetime('now'))
);
-- todo.title: Task title
-- todo.done: 0=pending, 1=done
CREATE INDEX "idx_done" ON "todo" ("done");
