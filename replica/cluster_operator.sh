#!/bin/bash
echo "=== 开始读写测试 ==="

REDIS_PASSWORD="A8K5h7+6!?"
MYSQL_PASSWORD="s<9!Own1z4"

# Redis测试
echo "1. Redis写测试:"
redis-cli -c -h 10.18.30.11 -p 6379 -a "$REDIS_PASSWORD" set test_key "value_$(date +%s)"
redis-cli -c -h 10.18.30.12 -p 6379 -a "$REDIS_PASSWORD" set test_key2 "value_$(date +%s)"

echo "2. Redis读测试:"
redis-cli -c -h 10.18.30.13 -p 6379 -a "$REDIS_PASSWORD" get test_key
redis-cli -c -h 10.18.30.11 -p 6379 -a "$REDIS_PASSWORD" get test_key2

# MySQL测试
echo -e "\n3. MySQL写测试:"
mysql -h 10.18.30.11 -P 6446 -u root -p"$MYSQL_PASSWORD" -e "
CREATE DATABASE IF NOT EXISTS test_db;
USE test_db;
CREATE TABLE IF NOT EXISTS test_table (id INT PRIMARY KEY, data VARCHAR(20), timestamp TIMESTAMP);
INSERT INTO test_table VALUES (1, 'test_data', NOW());
"

echo "4. MySQL读测试:"
mysql -h 10.18.30.12 -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT * FROM test_db.test_table;"

# etcd测试
echo -e "\n5. etcd写测试:"
ETCDCTL_API=3 etcdctl --endpoints=10.18.30.11:2379 put test_key "etcd_value_$(date +%s)"

echo "6. etcd读测试:"
ETCDCTL_API=3 etcdctl --endpoints=10.18.30.13:2379 get test_key