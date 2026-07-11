CREATE TABLE `order_item` (
  `order_id` int NOT NULL,
  `product_id` int NOT NULL,
  `quantity` int NOT NULL DEFAULT 1,
  `price` decimal(10, 2) NOT NULL,
  PRIMARY KEY (`order_id`, `product_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
