#!/bin/bash
# 当节点成为 Keepalived MASTER 时执行

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"
REDIS_PASS="A8K5h7+6!?"
CURRENT_IP=$(hostname -I | awk '{print $1}')

echo "$(date): [REDIS NOTIFY] Becoming MASTER. Promoting Redis if needed..." >> $LOG 2>&1

# 获取当前 Redis 角色
ROLE=$(docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')

if [ "$ROLE" = "slave" ]; then
    echo "$(date): Current role is SLAVE, promoting to MASTER..." >> $LOG 2>&1
    
    # 1. 停止复制（提升为主库）
    docker exec -i redis redis-cli -a "A8K5h7+6!?" slaveof no one 2>> $LOG 2>&1
    
    # 2. 等待提升完成
    sleep 3
    
    # 3. 验证角色
    NEW_ROLE=$(docker exec -i redis redis-cli -a "A8K5h7+6!?" info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    echo "$(date): New role is $NEW_ROLE" >> $LOG 2>&1
    
elif [ "$ROLE" = "master" ]; then
    echo "$(date): Already MASTER, no action needed" >> $LOG 2>&1
else
    echo "$(date): ERROR: Unknown Redis role: $ROLE" >> $LOG 2>&1
fi

echo "$(date): [REDIS NOTIFY] MASTER transition complete" >> $LOG 2>&1