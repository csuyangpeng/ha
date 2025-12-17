#!/bin/bash
# /home/sder/ha/replica/scripts/notify_master_wrapper.sh

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"

echo "$(date): [WRAPPER] Starting MASTER transition" >> $LOG

# 1. 先执行 MySQL 提升
if [ -x "/home/sder/ha/replica/scripts/mysql_notify_master.sh" ]; then
    echo "$(date): Executing MySQL master script..." >> $LOG
    /home/sder/ha/replica/scripts/mysql_notify_master.sh >> $LOG 2>&1
    MYSQL_STATUS=$?
    echo "$(date): MySQL script exit code: $MYSQL_STATUS" >> $LOG
fi

# 2. 再执行 Redis 提升
if [ -x "/home/sder/ha/replica/scripts/redis_notify_master.sh" ]; then
    echo "$(date): Executing Redis master script..." >> $LOG
    /home/sder/ha/replica/scripts/redis_notify_master.sh >> $LOG 2>&1
    REDIS_STATUS=$?
    echo "$(date): Redis script exit code: $REDIS_STATUS" >> $LOG
fi

# 3. Etcd 检查（Etcd 不需要特殊操作）
if [ -x "/home/sder/ha/replica/scripts/etcd_notify_master.sh" ]; then
    echo "$(date): Executing Etcd master script..." >> $LOG
    /home/sder/ha/replica/scripts/etcd_notify_master.sh >> $LOG 2>&1
    ETCD_STATUS=$?
fi

echo "$(date): [WRAPPER] MASTER transition completed" >> $LOG

if [ $MYSQL_STATUS -eq 0 ] && [ $REDIS_STATUS -eq 0 ]; then
    exit 0
else
    exit 1
fi