#!/bin/bash
# notify_backup.sh - 当节点成为Keepalived BACKUP时，将MySQL降级为Slave
LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"
NEW_MASTER_IP="10.18.1.30"  # 通过VIP连接，总是指向当前主库
# 也可以直接指定新主库IP: NEW_MASTER_IP="10.18.1.28"
MYSQL_USER='root'
MYSQL_PASS='s<9!Own1z4'

echo "$(date): [NOTIFY] Becoming BACKUP. Demoting MySQL to SLAVE..." >> $LOG 2>&1

# 6. 确保本机处于只读状态
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SET GLOBAL read_only=ON;SET GLOBAL super_read_only=ON;" >> $LOG 2>&1

docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SHOW MASTER STATUS\G SHOW SLAVE STATUS\G" >> $LOG 2>&1

# 1. 停止当前的复制进程（如果存在）
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "STOP SLAVE;" >> $LOG 2>&1

# . 彻底重置复制状态，清除所有旧的master信息
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET SLAVE ALL;" >> $LOG 2>&1

# 3. 【关键】如果原主库曾写入数据，需谨慎处理（见下文说明）
# 方案A（安全）：不清理数据，但需确保GTID或日志位置能接续
# 方案B（彻底）：清除可能冲突的数据（仅用于测试或可丢失数据的场景）
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "RESET MASTER;" >> $LOG 2>&1

# 4. 指向新的主库（通过VIP，确保始终连接到当前活动主库）
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 <<EOF >> $LOG 2>&1
CHANGE MASTER TO
MASTER_HOST='10.18.1.28',
MASTER_USER='root',
MASTER_PASSWORD='s<9!Own1z4',
MASTER_PORT=3306,
MASTER_AUTO_POSITION=1,
MASTER_CONNECT_RETRY=10;
EOF

# 5. 启动复制
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "START SLAVE;" >> $LOG 2>&1

# 7. 检查复制状态
echo "$(date): [NOTIFY] Checking slave status..." >> $LOG 2>&1
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SHOW SLAVE STATUS\G" >> $LOG 2>&1

echo "$(date): [NOTIFY] MySQL demotion to SLAVE finished." >> $LOG 2>&1
