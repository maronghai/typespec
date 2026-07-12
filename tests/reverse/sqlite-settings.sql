CREATE TABLE "settings" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "key" TEXT NOT NULL UNIQUE,
  "value" TEXT,
  "updated_at" TEXT DEFAULT (datetime('now'))
);
