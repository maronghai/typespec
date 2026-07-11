CREATE TABLE "customer" (
  "id" integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  "name" varchar(100) NOT NULL,
  "email" varchar(255) NOT NULL,
  "created_at" timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);
COMMENT ON TABLE "customer" IS 'Customer accounts';
COMMENT ON COLUMN "customer"."name" IS 'Full name';
COMMENT ON COLUMN "customer"."email" IS 'Contact email';
CREATE UNIQUE INDEX "uk_email" ON "customer" ("email");
