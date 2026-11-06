#!/bin/bash
# keepalived notify_master：提升 MySQL -> 提升 Redis -> 启动 etcdvip
source "/home/sder/ha/replica/scripts/base.sh"

echo "[WRAPPER] Starting MASTER transition" >> "$LOG"

MYSQL_STATUS=0
REDIS_STATUS=0
ETCD_STATUS=0

echo "Executing MySQL master script..." >> "$LOG"
"$SCRIPT_DIR/mysql_notify_master.sh" 2>&1 | _ts_pipe >> "$LOG"
MYSQL_STATUS=${PIPESTATUS[0]}
echo "MySQL script exit code: $MYSQL_STATUS" >> "$LOG"

echo "Executing Redis master script..." >> "$LOG"
"$SCRIPT_DIR/redis_notify_master.sh" 2>&1 | _ts_pipe >> "$LOG"
REDIS_STATUS=${PIPESTATUS[0]}
echo "Redis script exit code: $REDIS_STATUS" >> "$LOG"

echo "Executing Etcd master script..." >> "$LOG"
"$SCRIPT_DIR/etcd_notify_master.sh" 2>&1 | _ts_pipe >> "$LOG"
ETCD_STATUS=${PIPESTATUS[0]}
echo "Etcd script exit code: $ETCD_STATUS" >> "$LOG"

echo "[WRAPPER] MASTER transition completed" >> "$LOG"

[ "$MYSQL_STATUS" -eq 0 ] && [ "$REDIS_STATUS" -eq 0 ] && [ "$ETCD_STATUS" -eq 0 ]
