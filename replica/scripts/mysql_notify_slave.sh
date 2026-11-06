#!/bin/bash
# 节点成为 BACKUP：把本机 MySQL 降级为 VIP 指向的从库
# 关键点：
#   1. 复制源统一使用 VIP（10.18.1.30），避免写死某一台节点；
#   2. 只做 RESET SLAVE ALL，不执行 RESET MASTER，保留本机 binlog 历史；
#   3. 结束后校验 IO/SQL 线程确实在跑，失败返回非 0（由健康检查脚本兜底重建）。
source "/home/sder/ha/replica/scripts/base.sh"

MASTER_HOST="$MYSQL_VIP"

echo "[NOTIFY] Becoming BACKUP. Demoting MySQL to SLAVE of ${MASTER_HOST}..." 2>&1 | _ts_pipe >> "$LOG"

if ! mysql_alive; then
    echo "[ERROR] MySQL 不可用，无法降级" 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi

# 1. 先置只读，避免降级过程中继续写入
mysql_exec -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" 2>&1 | _ts_pipe >> "$LOG"

mysql_exec -e "SHOW MASTER STATUS\G SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"

# 2. 清理旧复制关系（不动 binlog）
mysql_exec -e "STOP SLAVE;" 2>&1 | _ts_pipe >> "$LOG"
mysql_exec -e "RESET SLAVE ALL;" 2>&1 | _ts_pipe >> "$LOG"

# 3. 指向 VIP 主库（GTID 自动定位）
mysql_exec <<EOF 2>&1 | _ts_pipe >> "$LOG"
CHANGE MASTER TO
  MASTER_HOST='${MASTER_HOST}',
  MASTER_USER='${MYSQL_USER}',
  MASTER_PASSWORD='${MYSQL_PASS}',
  MASTER_PORT=${MYSQL_PORT},
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
EOF

# 4. 启动复制
mysql_exec -e "START SLAVE;" 2>&1 | _ts_pipe >> "$LOG"

# 5. 校验（给复制线程最多 30 秒建链时间）
IO_RUNNING=""
SQL_RUNNING=""
for _ in $(seq 1 30); do
    STATUS=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    IO_RUNNING=$(echo "$STATUS" | awk -F': ' '/Slave_IO_Running:/{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
    [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ] && break
    sleep 1
done

mysql_exec -e "SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    echo "[NOTIFY] MySQL demotion to SLAVE finished (master=${MASTER_HOST})." 2>&1 | _ts_pipe >> "$LOG"
    exit 0
fi

echo "[ERROR] 复制未建立：IO_Running=${IO_RUNNING:-unknown}, SQL_Running=${SQL_RUNNING:-unknown}" 2>&1 | _ts_pipe >> "$LOG"
exit 1
