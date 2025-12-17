#!/bin/bash
# 当节点成为 Keepalived BACKUP 时执行

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"
REDIS_PASS="A8K5h7+6!?"
MASTER_IP="10.18.1.30"  # 通过 VIP 连接当前主库

echo "$(date): [REDIS NOTIFY] Becoming BACKUP. Configuring as SLAVE..." >> $LOG 2>&1

# 获取当前 Redis 角色
ROLE=$(docker exec -i redis redis-cli -a "A8K5h7+6!?" info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')

if [ "$ROLE" = "master" ]; then
    echo "$(date): Current role is MASTER, demoting to SLAVE of $MASTER_IP..." >> $LOG 2>&1
    
    # 配置为指定主库的从库
    docker exec -i redis redis-cli -a "A8K5h7+6!?" slaveof $MASTER_IP 6379 >> $LOG 2>&1
    
    # 等待配置生效
    sleep 3
    
    # 验证角色
    NEW_ROLE=$(docker exec -i redis redis-cli -a "A8K5h7+6!?" info replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    echo "$(date): New role is $NEW_ROLE" >> $LOG 2>&1
    
elif [ "$ROLE" = "slave" ]; then
    # 如果已经是从库，检查是否需要切换主库
    CURRENT_MASTER=$(docker exec -i redis redis-cli -a "A8K5h7+6!?" info replication 2>/dev/null | grep "master_host:" | cut -d: -f2 | tr -d '\r')
    if [ "$CURRENT_MASTER" != "$MASTER_IP" ]; then
        echo "$(date): Switching master from $CURRENT_MASTER to $MASTER_IP" >> $LOG 2>&1
        docker exec -i redis redis-cli -a "A8K5h7+6!?" slaveof $MASTER_IP 6379 >> $LOG 2>&1
    else
        echo "$(date): Already SLAVE of correct master $MASTER_IP" >> $LOG 2>&1
    fi
fi

echo "$(date): [REDIS NOTIFY] BACKUP transition complete" >> $LOG 2>&1