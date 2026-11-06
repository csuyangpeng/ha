#!/bin/bash
# keepalived notify_backup / notify_fault / notify_stop：
# 将 MySQL 降级为从库 -> 将 Redis 降级为从库 -> 停止 etcdvip
source "/home/sder/ha/replica/scripts/base.sh"

echo "[WRAPPER] Starting BACKUP transition" >> "$LOG"

MYSQL_STATUS=0
REDIS_STATUS=0
ETCD_STATUS=0

echo "Executing MySQL slave script..." >> "$LOG"
"$SCRIPT_DIR/mysql_notify_slave.sh" 2>&1 | _ts_pipe >> "$LOG"
MYSQL_STATUS=${PIPESTATUS[0]}
echo "MySQL script exit code: $MYSQL_STATUS" >> "$LOG"

echo "Executing Redis slave script..." >> "$LOG"
"$SCRIPT_DIR/redis_notify_slave.sh" 2>&1 | _ts_pipe >> "$LOG"
REDIS_STATUS=${PIPESTATUS[0]}
echo "Redis script exit code: $REDIS_STATUS" >> "$LOG"

echo "Executing Etcd slave script..." >> "$LOG"
"$SCRIPT_DIR/etcd_notify_slave.sh" 2>&1 | _ts_pipe >> "$LOG"
ETCD_STATUS=${PIPESTATUS[0]}
echo "Etcd script exit code: $ETCD_STATUS" >> "$LOG"

echo "[WRAPPER] BACKUP transition completed" >> "$LOG"

[ "$MYSQL_STATUS" -eq 0 ] && [ "$REDIS_STATUS" -eq 0 ] && [ "$ETCD_STATUS" -eq 0 ]
