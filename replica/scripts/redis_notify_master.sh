#!/bin/bash
# 当节点成为 Keepalived MASTER 时执行

source "/home/sder/ha/replica/scripts/base.sh"

REDIS_PASS="A8K5h7+6!?"
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "[REDIS NOTIFY] Becoming MASTER. Promoting Redis if needed..." 2>&1 | _ts_pipe >> "$LOG"

# 获取当前 Redis 角色
ROLE=$(docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')

if [ "$ROLE" = "slave" ]; then
    echo "Current role is SLAVE, promoting to MASTER..." 2>&1 | _ts_pipe >> "$LOG"
    
    # 1. 停止复制（提升为主库）
    docker exec -i redis redis-cli -a "A8K5h7+6!?" slaveof no one 2>> $LOG 2>&1
    
    # 2. 等待提升完成
    sleep 3
    
    # 3. 验证角色
    NEW_ROLE=$(docker exec -i redis redis-cli -a "A8K5h7+6!?" info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    echo "New role is $NEW_ROLE" 2>&1 | _ts_pipe >> "$LOG"
    
elif [ "$ROLE" = "master" ]; then
    echo "Already MASTER, no action needed" 2>&1 | _ts_pipe >> "$LOG"
else
    echo "ERROR: Unknown Redis role: $ROLE" 2>&1 | _ts_pipe >> "$LOG"
fi

echo "[REDIS NOTIFY] MASTER transition complete" 2>&1 | _ts_pipe >> "$LOG"