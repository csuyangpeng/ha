#!/bin/bash
LOG="/home/sder/ha/replica/logs/keepalived-mysql.log"
echo "$(date): [NOTIFY] Becoming MASTER. Promoting MySQL..." >> $LOG

MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"
# 1. 停止复制线程
docker exec -it mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "STOP SLAVE;" 2>> $LOG

# 2. 重置从库状态，解除与原主的关系
docker exec -it mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET SLAVE ALL;" 2>> $LOG

# 3. 【重要】确保本机可写，成为主库。这是最关键的一步。
docker exec -it mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SET GLOBAL read_only=OFF;" 2>> $LOG

# # 重置master日志状态（可选，适用于计划构建新的复制集群）
# mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET MASTER;" 2>> $LOG

# 4. 【可选但建议】创建一个新的binlog文件，使日志更清晰。这与 RESET MASTER 完全不同！
#    FLUSH BINARY LOGS 会关闭当前binlog并新建一个，不会删除任何历史日志。
docker exec -it mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "FLUSH BINARY LOGS;" 2>> $LOG

echo "$(date): [NOTIFY] MySQL promotion to MASTER finished (binlog history PRESERVED)." >> $LOG
