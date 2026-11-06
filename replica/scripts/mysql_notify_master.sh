#!/bin/bash
# 节点成为 MASTER：把本机 MySQL 提升为可写主库
# 关键点：
#   1. 若本机是复制节点，先停 IO 线程并等 SQL 线程把 relay log 应用完，尽量减少事务丢失；
#   2. 不执行 RESET MASTER，保留 binlog 历史（GTID + AUTO_POSITION 不需要重置）；
#   3. 结束后校验确实可写，失败返回非 0。
source "/home/sder/ha/replica/scripts/base.sh"

echo "[NOTIFY] Becoming MASTER. Promoting MySQL..." 2>&1 | _ts_pipe >> "$LOG"

# 提升期间打标记，健康检查脚本据此容忍"持有 VIP 但仍只读"的过渡窗口
date +%s > "$PROMOTE_FLAG"
trap 'rm -f "$PROMOTE_FLAG"' EXIT

if ! mysql_alive; then
    echo "[ERROR] MySQL 不可用，无法提升" 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi

mysql_exec -e "SHOW MASTER STATUS\G SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"

# 1. 若是从库：停止 IO 线程，等待已有 relay log 全部应用
if mysql_exec -e "SHOW SLAVE STATUS" 2>/dev/null | grep -q "Master_Host"; then
    mysql_exec -e "STOP SLAVE IO_THREAD;" 2>&1 | _ts_pipe >> "$LOG"

    DRAINED=0
    for _ in $(seq 1 30); do
        STATE=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null | awk -F': ' '/Slave_SQL_Running_State:/{print $2}')
        case "$STATE" in
            *"read all relay log"*) DRAINED=1; break ;;
        esac
        sleep 1
    done
    if [ "$DRAINED" -eq 1 ]; then
        echo "[NOTIFY] relay log 已应用完毕" 2>&1 | _ts_pipe >> "$LOG"
    else
        echo "[WARN] 等待 relay log 应用超时（状态: ${STATE:-unknown}），继续提升" 2>&1 | _ts_pipe >> "$LOG"
    fi
else
    echo "[NOTIFY] 本机不是复制节点，跳过 relay log 排空" 2>&1 | _ts_pipe >> "$LOG"
fi

# 2. 停止并解除复制
mysql_exec -e "STOP SLAVE;" 2>&1 | _ts_pipe >> "$LOG"
mysql_exec -e "RESET SLAVE ALL;" 2>&1 | _ts_pipe >> "$LOG"

# 3. 允许写入
mysql_exec -e "SET GLOBAL read_only=OFF; SET GLOBAL super_read_only=OFF;" 2>&1 | _ts_pipe >> "$LOG"

# 4. 新建一个 binlog 文件（不删除历史日志）
mysql_exec -e "FLUSH BINARY LOGS;" 2>&1 | _ts_pipe >> "$LOG"

# 5. 校验
READ_ONLY=$(mysql_query "SELECT @@global.read_only" | tr -d '[:space:]')
if [ "$READ_ONLY" != "0" ]; then
    echo "[ERROR] 提升失败：read_only=${READ_ONLY:-unknown}" 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi

echo "[NOTIFY] MySQL promotion to MASTER finished (binlog history preserved)." 2>&1 | _ts_pipe >> "$LOG"
exit 0
