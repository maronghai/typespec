CREATE TABLE `order_status` (
  `id` int AUTO_INCREMENT PRIMARY KEY,
  `status` enum('pending', 'confirmed', 'shipped', 'delivered') NOT NULL,
  `priority` enum('low', 'medium', 'high') DEFAULT 'medium',
  `name` varchar(100) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
