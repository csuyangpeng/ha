#!/bin/bash
echo "=== 集群初始状态检查 ==="

REDIS_PASSWORD="A8K5h7+6!?"
MYSQL_PASSWORD="s<9!Own1z4"

# 检查节点连通性并确定主控节点
echo "1. 节点网络连通性检查:"
MASTER_NODE=""
for node in 11 12 13; do
    if ping -W 1 -c 1 10.18.30.$node &> /dev/null; then
        echo "✅ 10.18.30.$node 可达"
        if [ -z "$MASTER_NODE" ]; then
            MASTER_NODE="10.18.30.$node"
        fi
    else
        echo "❌ 10.18.30.$node 不可达"
    fi
done

if [ -z "$MASTER_NODE" ]; then
    echo "❌ 所有节点都不可达，退出检查"
    exit 1
fi

echo -e "\n✅ 使用主控节点: $MASTER_NODE"

# 检查Redis集群
echo -e "\n2. Redis集群状态:"
timeout 2 redis-cli -c -h $MASTER_NODE -p 6379 -a "$REDIS_PASSWORD" cluster nodes 2>/dev/null | head -10
if [ $? -ne 0 ]; then
    echo "❌ Redis集群检查失败或超时"
fi

# 检查MySQL MGR
echo -e "\n3. MySQL MGR状态:"
timeout 2 mysql -h $MASTER_NODE -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT * FROM performance_schema.replication_group_members;" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ MySQL MGR检查失败或超时"
fi

# 检查etcd集群
echo -e "\n4. etcd集群状态:"
timeout 2 ETCDCTL_API=3 etcdctl --endpoints=10.18.30.11:2379,10.18.30.12:2379,10.18.30.13:2379 endpoint status --write-out=table 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ etcd集群检查失败或超时"
fi

# 检查MySQL Router
echo -e "\n5. MySQL Router连接测试:"
timeout 2 mysql -h $MASTER_NODE -P 6446 -u root -p"$MYSQL_PASSWORD" -e "SELECT @@server_id;" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ MySQL Router检查失败或超时"
fi

# 额外检查：尝试所有节点的Redis连接
echo -e "\n6. 所有节点Redis连接测试:"
for node in 11 12 13; do
    if ping -W 1 -c 1 10.18.30.$node &> /dev/null; then
        echo -n "10.18.30.$node: "
        timeout 5 redis-cli -h 10.18.30.$node -p 6379 -a "$REDIS_PASSWORD" ping 2>/dev/null | grep -q PONG && echo "✅" || echo "❌"
    fi
done