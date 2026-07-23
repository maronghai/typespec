-- SQL with non-standard DEFAULT expressions
CREATE TABLE orders (
    id int NOT NULL AUTO_INCREMENT,
    status varchar(32) DEFAULT 'pending',
    amount decimal(10, 2) DEFAULT 0.00,
    discount decimal(5, 2) DEFAULT -1.00,
    created_at datetime DEFAULT CURRENT_TIMESTAMP,
    updated_at datetime DEFAULT NULL,
    note text,
    PRIMARY KEY (id)
);
