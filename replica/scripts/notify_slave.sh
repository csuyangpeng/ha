#!/bin/bash
# /home/sder/ha/replica/scripts/notify_backup_wrapper.sh

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"

echo "$(date): [WRAPPER] Starting BACKUP transition" >> $LOG

# 1. 先执行 MySQL 降级
if [ -x "/home/sder/ha/replica/scripts/mysql_notify_slave.sh" ]; then
    echo "$(date): Executing MySQL slave script..." >> $LOG
    /home/sder/ha/replica/scripts/mysql_notify_slave.sh >> $LOG 2>&1
    MYSQL_STATUS=$?
    echo "$(date): MySQL script exit code: $MYSQL_STATUS" >> $LOG
fi

# 2. 再执行 Redis 降级
if [ -x "/home/sder/ha/replica/scripts/redis_notify_slave.sh" ]; then
    echo "$(date): Executing Redis slave script..." >> $LOG
    /home/sder/ha/replica/scripts/redis_notify_slave.sh >> $LOG 2>&1
    REDIS_STATUS=$?
    echo "$(date): Redis script exit code: $REDIS_STATUS" >> $LOG
fi

# 3. Etcd 检查（Etcd 不需要特殊操作）
if [ -x "/home/sder/ha/replica/scripts/etcd_notify_slave.sh" ]; then
    echo "$(date): Executing Etcd slave script..." >> $LOG
    /home/sder/ha/replica/scripts/etcd_notify_slave.sh >> $LOG 2>&1
    ETCD_STATUS=$?
fi

echo "$(date): [WRAPPER] BACKUP transition completed" >> $LOG

# 如果两个脚本都成功返回 0，否则返回失败代码
if [ $MYSQL_STATUS -eq 0 ] && [ $REDIS_STATUS -eq 0 ] && [ $ETCD_STATUS -eq 0 ]; then
    exit 0
else
    exit 1
fi