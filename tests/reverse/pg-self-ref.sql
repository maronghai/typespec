CREATE TABLE "categories" (
  "id" integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "name" varchar(128) NOT NULL,
  "parent_id" integer,
  FOREIGN KEY ("parent_id") REFERENCES "categories"("id") ON DELETE SET NULL
);
COMMENT ON TABLE "categories" IS 'Category tree';
CREATE INDEX "idx_parent" ON "categories" ("parent_id");
