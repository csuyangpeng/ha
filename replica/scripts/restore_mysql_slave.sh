#!/bin/bash
# restore_mysql_slave.sh

source "/home/sder/ha/replica/scripts/base.sh"

# 配置
MASTER_IP="10.18.1.28"
SLAVE_IP="10.18.1.27"
MYSQL_PASS='s<9!Own1z4'
BACKUP_FILE="/tmp/master_dump.sql"

echo "=== 恢复 $SLAVE_IP MySQL 从库 ==="

# 1. 在主库创建备份
echo "1. 在主库 ($MASTER_IP) 创建备份..." 2>&1 | _ts_pipe >> "$LOG"
ssh $MASTER_IP "docker exec mysql mysqldump -uroot -p's<9!Own1z4' \
  --all-databases \
  --single-transaction \
  --master-data=2 \
  --set-gtid-purged=ON \
  > $BACKUP_FILE" 2>&1 | _ts_pipe >> "$LOG"

# 2. 复制备份文件
echo "2. 复制备份文件到从库..." 2>&1 | _ts_pipe >> "$LOG"
scp $MASTER_IP:$BACKUP_FILE $BACKUP_FILE 2>&1 | _ts_pipe >> "$LOG"

# 3. 停止从库 MySQL
echo "3. 停止从库 MySQL 容器..." 2>&1 | _ts_pipe >> "$LOG"
docker stop mysql 2>&1 | _ts_pipe >> "$LOG"
docker rm mysql 2>&1 | _ts_pipe >> "$LOG"
sudo rm -rf /home/sder/ha/replica/data/mysql/*  2>&1 | _ts_pipe >> "$LOG"
# docker volume rm mysql_data 2>/dev/null || true

# 4. 重新创建容器
echo "4. 重新创建 MySQL 容器..." 2>&1 | _ts_pipe >> "$LOG"
pushd /home/sder/ha/replica && docker-compose up -d mysql && popd  2>&1 | _ts_pipe >> "$LOG"
# docker run -d \
#   --name mysql \
#   -e MYSQL_ROOT_PASSWORD='s<9!Own1z4' \
#   -v mysql_data:/var/lib/mysql \
#   -p 3306:3306 \
#   mysql:8.0 \
#   --server-id=2

# 5. 等待启动
echo "5. 等待 MySQL 启动..." 2>&1 | _ts_pipe >> "$LOG"

# wait until mysql is ready
until docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT 1;" &> /dev/null; do
  echo "等待 MySQL 启动..." 2>&1 | _ts_pipe >> "$LOG"
  sleep 3
done
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT 1;" 2>&1 | _ts_pipe >> "$LOG"

# 6. 导入数据
echo "6. 导入数据..." 2>&1 | _ts_pipe >> "$LOG"
docker cp $BACKUP_FILE mysql:/tmp/dump.sql 2>&1 | _ts_pipe >> "$LOG"
docker exec mysql bash -c "mysql -uroot -p's<9!Own1z4' < /tmp/dump.sql" 2>&1 | _ts_pipe >> "$LOG"

# 7. 配置复制
echo "7. 配置复制..." 2>&1 | _ts_pipe >> "$LOG"
docker exec -i mysql mysql -uroot -p's<9!Own1z4' << EOF 2>&1 | _ts_pipe >> "$LOG"
SET GLOBAL read_only=ON;SET GLOBAL super_read_only=ON;
STOP SLAVE;
# RESET MASTER;
RESET SLAVE ALL;

CHANGE MASTER TO
  MASTER_HOST='$MASTER_IP',
  MASTER_USER='root',
  MASTER_PASSWORD='s<9!Own1z4',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;

START SLAVE;
EOF

# 8. 检查状态
echo "8. 检查状态..." 2>&1 | _ts_pipe >> "$LOG"
docker exec mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" 2>&1 | _ts_pipe >> "$LOG"

echo "✅ 恢复完成！" 2>&1 | _ts_pipe >> "$LOG"