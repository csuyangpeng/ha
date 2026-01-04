#!/bin/bash

source /home/sder/ha/replica/scripts/base.sh

# 首先检查MySQL容器状态并获取正确的容器名
echo "检查MySQL容器状态..."

# 创建MySQL测试数据库
docker exec -i mysql mysql -h $MYSQL_VIP -u $MYSQL_USER -p"$MYSQL_PASS" -e "
CREATE DATABASE IF NOT EXISTS ha_test_db;
USE ha_test_db;
CREATE TABLE IF NOT EXISTS test_data (
    id INT AUTO_INCREMENT PRIMARY KEY,
    data VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    source_node VARCHAR(50),
    test_case VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS test_results (
    id INT AUTO_INCREMENT PRIMARY KEY,
    test_name VARCHAR(100),
    test_case VARCHAR(100),
    status ENUM('PASS', 'FAIL', 'WARNING'),
    details TEXT,
    duration INT,
    test_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    node VARCHAR(50)
);
" 2>/dev/null || echo "注意: 无法连接到MySQL，请检查配置"