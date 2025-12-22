#!/bin/bash

LOG="/home/sder/ha/replica/logs/keepalived-mysql.log"
echo "[NOTIFY] Checking MySQL..." >> $LOG

MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"

# 检查MySQL服务是否可用的简单脚本
if docker exec -it mysql mysql -u$MYSQL_USER -p$MYSQL_PASS -h 127.0.0.1 -e "SELECT 1;" &> /dev/null; then
    echo "[NOTIFY] MySQL is available." >> $LOG
    exit 0
else
    echo "[ERROR] MySQL is not available." >> $LOG
    exit 1
fi
