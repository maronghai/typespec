-- ══════════════════════════════════════════════════════════════
-- Complex E-Commerce + SaaS Platform — SQL DDL Output
-- ══════════════════════════════════════════════════════════════
-- Generated from: complex-ecommerce.tps
-- ══════════════════════════════════════════════════════════════

CREATE DATABASE `ecommerce`;

-- ──────────────────────────────────────────────────────────────
-- User Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `user` (
  `id`              int AUTO_INCREMENT PRIMARY KEY,
  `name`            varchar(32) NOT NULL,
  `email`           varchar(128) NOT NULL,
  `password`        varchar(256) NOT NULL,
  `phone`           varchar(20),
  `avatar`          text,
  `bio`             varchar(512),
  `is_verified`     boolean DEFAULT 0,
  `is_admin`        boolean DEFAULT 0,
  `role`            int(1) DEFAULT 0 CHECK (role IN (0, 1, 2, 3)),
  `balance`         decimal(16, 2) DEFAULT 0,
  `settings`        json,
  `version`         bigint,
  `status`          int(1) DEFAULT 0,
  `create_at`       datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`       datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`      datetime,
  `deleted_by`      int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  UNIQUE INDEX `uk_email` (`email`),
  INDEX `idx_name` (`name`),
  INDEX `idx_phone` (`phone`),

  COMMENT = '用户表'
);

CREATE TABLE `user_address` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `user_id`     int,
  `label`       varchar(16) DEFAULT '',
  `province`    varchar(32),
  `city`        varchar(32),
  `district`    varchar(32),
  `address`     varchar(256) NOT NULL,
  `zip`         varchar(10),
  `phone`       varchar(20),
  `is_default`  boolean DEFAULT 0,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  INDEX `idx_user` (`user_id`),
  INDEX `idx_default` (`user_id`, `is_default`),

  COMMENT = '用户地址'
);

CREATE TABLE `user_oauth` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `user_id`     int,
  `provider`    varchar(32) NOT NULL,
  `open_id`     varchar(128) NOT NULL,
  `access_token` text,
  `refresh_token` text,
  `expires_on`  datetime,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
  UNIQUE INDEX `uk_provider_open` (`provider`, `open_id`),
  INDEX `idx_user` (`user_id`),

  COMMENT = '第三方登录'
);

-- ──────────────────────────────────────────────────────────────
-- Product Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `category` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(64) NOT NULL,
  `parent_id`   int,
  `sort_order`  int DEFAULT 0,
  `icon`        varchar(128),
  `is_active`   boolean DEFAULT 1,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  FOREIGN KEY (`parent_id`) REFERENCES `category`(`id`) ON DELETE SET NULL,
  INDEX `idx_parent` (`parent_id`),
  INDEX `idx_sort` (`sort_order`),

  COMMENT = '商品分类'
);

CREATE TABLE `brand` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(64) NOT NULL,
  `logo`        varchar(256),
  `description` text,
  `website`     varchar(256),
  `is_active`   boolean DEFAULT 1,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  UNIQUE INDEX `uk_name` (`name`),

  COMMENT = '品牌'
);

CREATE TABLE `product` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(128) NOT NULL,
  `subtitle`    varchar(256),
  `brand_id`    int,
  `category_id` int,
  `price`       decimal(16, 2) NOT NULL CHECK (price > 0),
  `market_price` decimal(16, 2) DEFAULT 0,
  `cost_price`  decimal(16, 2) DEFAULT 0,
  `stock`       int DEFAULT 0 CHECK (stock >= 0),
  `sales`       bigint DEFAULT 0,
  `weight`      decimal(20, 6) DEFAULT 0,
  `rating`      decimal(4, 2) DEFAULT 0,
  `raw_data`    blob,
  `is_on_sale`  boolean DEFAULT 1,
  `sort_order`  int DEFAULT 0,
  `main_image`  varchar(256),
  `images`      json,
  `attributes`  json,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  FOREIGN KEY (`brand_id`) REFERENCES `brand`(`id`) ON DELETE SET NULL,
  FOREIGN KEY (`category_id`) REFERENCES `category`(`id`) ON DELETE SET NULL,
  INDEX `idx_category` (`category_id`),
  INDEX `idx_brand` (`brand_id`),
  INDEX `idx_price` (`price`),
  INDEX `idx_sales` (`sales`),
  INDEX `idx_sale_status` (`is_on_sale`, `sort_order`),

  COMMENT = '商品表'
);

CREATE TABLE `product_sku` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `product_id`  int,
  `sku_code`    varchar(64) NOT NULL,
  `spec_name`   varchar(128) NOT NULL,
  `price`       decimal(16, 2) NOT NULL CHECK (price > 0),
  `stock`       int DEFAULT 0 CHECK (stock >= 0),
  `image`       varchar(256),
  `sort_order`  int DEFAULT 0,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`) ON DELETE CASCADE,
  UNIQUE INDEX `uk_sku_code` (`sku_code`),
  INDEX `idx_product` (`product_id`),

  COMMENT = '商品 SKU'
);

CREATE TABLE `product_review` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `product_id`  int,
  `user_id`     int,
  `order_id`    int,
  `rating`      int(1) NOT NULL CHECK (rating IN (1, 2, 3, 4, 5)),
  `title`       varchar(128),
  `content`     text,
  `images`      json,
  `is_anonymous` boolean DEFAULT 0,
  `reply`       text,
  `replied_on`  datetime,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`) ON DELETE CASCADE,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
  INDEX `idx_product` (`product_id`),
  INDEX `idx_user` (`user_id`),
  INDEX `idx_rating` (`rating`),

  COMMENT = '商品评价'
);

-- ──────────────────────────────────────────────────────────────
-- Order Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `coupon` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(64) NOT NULL,
  `code`        varchar(64) NOT NULL,
  `total`       int DEFAULT 0,
  `used`        int DEFAULT 0,
  `per_user`    int DEFAULT 1,
  `is_active`   boolean DEFAULT 1,
  `type`        int(1) DEFAULT 0 CHECK (type IN (0, 1, 2)),
  `min_amount`  decimal(16, 2) DEFAULT 0,
  `discount`    decimal(16, 2) DEFAULT 0,
  `max_discount` decimal(16, 2) DEFAULT 0,
  `start_on`    date,
  `end_on`      date,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_code` (`code`),

  COMMENT = '优惠券'
);

CREATE TABLE `order` (
  `id`              int AUTO_INCREMENT PRIMARY KEY,
  `order_no`        varchar(64) NOT NULL,
  `user_id`         int,
  `coupon_id`       int,
  `status`          int(1) DEFAULT 0 CHECK (status IN (0, 1, 2, 3, 4, 5)),
  `total`           decimal(16, 2) NOT NULL CHECK (total > 0),
  `discount`        decimal(16, 2) DEFAULT 0,
  `shipping`        decimal(16, 2) DEFAULT 0,
  `actual`          decimal(16, 2) NOT NULL CHECK (actual > 0),
  `payment_method`  varchar(32),
  `payment_no`      varchar(128),
  `note`            varchar(512),
  `paid_on`         datetime,
  `shipped_on`      datetime,
  `completed_on`    datetime,
  `version`         bigint,
  `status_x`        int(1) DEFAULT 0,
  `create_at`       datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`       datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`      datetime,
  `deleted_by`      int,
  `restore_token`   varchar(64),
  `restore_expires_on` date,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE NO ACTION,
  FOREIGN KEY (`coupon_id`) REFERENCES `coupon`(`id`) ON DELETE SET NULL,
  UNIQUE INDEX `uk_order_no` (`order_no`),
  INDEX `idx_user` (`user_id`),
  INDEX `idx_status` (`status`),
  INDEX `idx_paid` (`paid_on`),
  INDEX `idx_created` (`create_at`),

  COMMENT = '订单表'
);

CREATE TABLE `order_item` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `order_id`    int,
  `product_id`  int,
  `sku_id`      int,
  `product_name` varchar(128) NOT NULL,
  `sku_name`    varchar(128) NOT NULL,
  `price`       decimal(16, 2),
  `quantity`    int NOT NULL CHECK (quantity >= 1),
  `subtotal`    decimal(16, 2),
  `image`       varchar(256),
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`order_id`) REFERENCES `order`(`id`) ON DELETE CASCADE,
  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`) ON DELETE NO ACTION,
  FOREIGN KEY (`sku_id`) REFERENCES `product_sku`(`id`) ON DELETE SET NULL,
  INDEX `idx_order` (`order_id`),

  COMMENT = '订单商品'
);

CREATE TABLE `shipping` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `order_id`    int,
  `carrier`     varchar(32) NOT NULL,
  `tracking_no` varchar(64) NOT NULL,
  `status`      int(1) DEFAULT 0 CHECK (status IN (0, 1, 2, 3)),
  `shipped_on`  datetime,
  `delivered_on` datetime,
  `version`     bigint,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`order_id`) REFERENCES `order`(`id`) ON DELETE CASCADE,
  UNIQUE INDEX `uk_tracking` (`carrier`, `tracking_no`),
  INDEX `idx_order` (`order_id`),

  COMMENT = '物流信息'
);

-- ──────────────────────────────────────────────────────────────
-- Payment Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `payment` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `order_id`    int,
  `user_id`     int,
  `method`      varchar(32) NOT NULL,
  `amount`      decimal(16, 2) NOT NULL CHECK (amount > 0),
  `trade_no`    varchar(128),
  `status`      int(1) DEFAULT 0 CHECK (status IN (0, 1, 2, 3)),
  `paid_on`     datetime,
  `extra`       json,
  `version`     bigint,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`order_id`) REFERENCES `order`(`id`) ON DELETE RESTRICT,
  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE NO ACTION,
  INDEX `idx_order` (`order_id`),
  INDEX `idx_user` (`user_id`),
  INDEX `idx_trade` (`trade_no`),

  COMMENT = '支付记录'
);

-- ──────────────────────────────────────────────────────────────
-- Content Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `article` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `title`       varchar(256) NOT NULL,
  `slug`        varchar(128) NOT NULL,
  `content`     text NOT NULL,
  `summary`     varchar(512),
  `cover`       varchar(256),
  `category`    varchar(32) DEFAULT '',
  `tags`        json,
  `views`       bigint DEFAULT 0,
  `is_published` boolean DEFAULT 0,
  `published_on` datetime,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_slug` (`slug`),
  INDEX `idx_category` (`category`),
  INDEX `idx_published` (`is_published`, `published_on`),
  FULLTEXT INDEX `ft_content` (`title`, `content`),

  COMMENT = '文章/帮助中心'
);

CREATE TABLE `banner` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `title`       varchar(64) NOT NULL,
  `image`       varchar(256) NOT NULL,
  `link`        varchar(512),
  `position`    varchar(32) DEFAULT '',
  `sort_order`  int DEFAULT 0,
  `is_active`   boolean DEFAULT 1,
  `start_on`    date,
  `end_on`      date,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  INDEX `idx_position` (`position`, `is_active`),

  COMMENT = '轮播图'
);

-- ──────────────────────────────────────────────────────────────
-- Notification Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `notification` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `user_id`     int,
  `type`        varchar(32) NOT NULL,
  `title`       varchar(128) NOT NULL,
  `content`     text,
  `is_read`     boolean DEFAULT 0,
  `link`        varchar(512),
  `extra`       json,
  `version`     bigint,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `deleted_at`  datetime,
  `deleted_by`  int,

  FOREIGN KEY (`user_id`) REFERENCES `user`(`id`) ON DELETE CASCADE,
  INDEX `idx_user_read` (`user_id`, `is_read`),
  INDEX `idx_type` (`type`),

  COMMENT = '站内消息'
);

-- ──────────────────────────────────────────────────────────────
-- System Domain
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `setting` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `key`         varchar(128) NOT NULL,
  `value`       text,
  `category`    varchar(32) DEFAULT '',
  `updated_on`  datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_key` (`key`),
  INDEX `idx_category` (`category`),

  COMMENT = '系统配置'
);

CREATE TABLE `op_log` (
  `id`            bigint AUTO_INCREMENT PRIMARY KEY,
  `operator_id`   int,
  `operator_name` varchar(32),
  `action`        varchar(32) NOT NULL,
  `target`        varchar(32),
  `target_id`     bigint,
  `detail`        json,
  `ip`            varchar(64),
  `created_at`    datetime DEFAULT CURRENT_TIMESTAMP,

  INDEX `idx_operator` (`operator_id`),
  INDEX `idx_action` (`action`),
  INDEX `idx_target` (`target`, `target_id`),

  COMMENT = '操作日志'
);

-- ──────────────────────────────────────────────────────────────
-- Many-to-Many Junction Tables
-- ──────────────────────────────────────────────────────────────

CREATE TABLE `user_role` (
  `user_id` int,
  `role_id` int,

  PRIMARY KEY (`user_id`, `role_id`),
  INDEX `idx_role` (`role_id`),

  COMMENT = '用户角色关联'
);

CREATE TABLE `product_tag` (
  `product_id` int,
  `tag_id`     int,

  PRIMARY KEY (`product_id`, `tag_id`),
  FOREIGN KEY (`product_id`) REFERENCES `product`(`id`) ON DELETE CASCADE,
  FOREIGN KEY (`tag_id`) REFERENCES `tag`(`id`) ON DELETE NO ACTION,
  INDEX `idx_tag` (`tag_id`),

  COMMENT = '商品标签关联'
);

CREATE TABLE `tag` (
  `id`          int AUTO_INCREMENT PRIMARY KEY,
  `name`        varchar(32) NOT NULL,
  `color`       varchar(7) DEFAULT '',
  `usage_count` int DEFAULT 0,
  `version`     bigint,
  `status`      int(1) DEFAULT 0,
  `create_at`   datetime DEFAULT CURRENT_TIMESTAMP,
  `update_at`   datetime DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  UNIQUE INDEX `uk_name` (`name`),

  COMMENT = '标签'
);
