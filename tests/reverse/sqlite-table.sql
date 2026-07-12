CREATE TABLE "inventory" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "product_id" INTEGER NOT NULL,
  "quantity" INTEGER NOT NULL DEFAULT 0,
  "location" TEXT,
  "updated_at" TEXT DEFAULT (datetime('now')),
  FOREIGN KEY ("product_id") REFERENCES "products"("id")
);
-- inventory.location: Warehouse location
CREATE INDEX "idx_product" ON "inventory" ("product_id");
