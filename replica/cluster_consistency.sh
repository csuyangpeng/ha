#!/bin/bash
echo "=== 数据一致性验证 ==="

REDIS_PASSWORD="A8K5h7+6!?"
MYSQL_PASSWORD="s<9!Own1z4"

# Redis数据一致性检查
echo "30. Redis数据一致性:"
for node in 11 12 13; do
    value=$(redis-cli -c -h 10.18.30.$node -p 6379 -a "$REDIS_PASSWORD" get test_key 2>/dev/null)
    echo "节点 10.18.30.$node: test_key = $value"
done

# MySQL数据一致性检查
echo -e "\n2. MySQL数据一致性:"
for node in 11 12 13; do
    if ping -c 1 10.18.30.$node &> /dev/null; then
        count=$(mysql -h 10.18.30.$node -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT COUNT(*) FROM test_db.test_table;" 2>/dev/null | tail -1)
        echo "节点 10.18.30.$node: 记录数 = $count"
    else
        echo "节点 10.18.30.$node: 不可达"
    fi
done

# etcd数据一致性检查
echo -e "\n3. etcd数据一致性:"
for node in 11 12 13; do
    if ping -c 1 10.18.30.$node &> /dev/null; then
        value=$(ETCDCTL_API=3 etcdctl --endpoints=10.18.30.$node:2379 get test_key 2>/dev/null | grep -v "Key not found")
        echo "节点 10.18.30.$node: test_key = $value"
    else
        echo "节点 10.18.30.$node: 不可达"
    fi
done