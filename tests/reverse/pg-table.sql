CREATE TABLE "users" (
  "id" integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "name" varchar(128) NOT NULL,
  "email" varchar(255) NOT NULL,
  "created_at" timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE "users" IS 'User accounts';
COMMENT ON COLUMN "users"."email" IS 'Primary email';
CREATE UNIQUE INDEX "uk_email" ON "users" ("email");
