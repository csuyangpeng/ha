#!/bin/bash

source "/home/sder/ha/replica/scripts/base.sh"

echo "[NOTIFY] Becoming MASTER. Promoting MySQL..." 2>&1 | _ts_pipe >> "$LOG"

MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"

docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SHOW MASTER STATUS\G SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"

# 1. 停止复制线程
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "STOP SLAVE;" 2>&1 | _ts_pipe >> "$LOG"

# . 重置从库状态，解除与原主的关系
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET SLAVE ALL;" 2>&1 | _ts_pipe >> "$LOG"

# 3. 【重要】确保本机可写，成为主库。这是最关键的一步。
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SET GLOBAL read_only=OFF;SET GLOBAL super_read_only=OFF;" 2>&1 | _ts_pipe >> "$LOG"

# # 重置master日志状态（可选，适用于计划构建新的复制集群）
# docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET MASTER;" 2>&1 | _ts_pipe >> "$LOG"

# 4. 【可选但建议】创建一个新的binlog文件，使日志更清晰。这与 RESET MASTER 完全不同！
#    FLUSH BINARY LOGS 会关闭当前binlog并新建一个，不会删除任何历史日志。
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "FLUSH BINARY LOGS;" 2>&1 | _ts_pipe >> "$LOG"

docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"
echo "[NOTIFY] MySQL promotion to MASTER finished (binlog history PRESERVED)." 2>&1 | _ts_pipe >> "$LOG"
