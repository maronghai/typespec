CREATE TABLE `product` (
  `id` int AUTO_INCREMENT PRIMARY KEY,
  `name` varchar(128) NOT NULL,
  `price` decimal(10, 2) NOT NULL,
  `quantity` int NOT NULL DEFAULT 0,
  `status` varchar(20) NOT NULL DEFAULT 'active',
  CHECK (`price` > 0 AND `price` < 10000),
  CHECK (`quantity` >= 0),
  CHECK (`status` IN ('active', 'inactive', 'discontinued'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
