#!/bin/bash
# MySQL HA 测试配置

# Keepalived 节点配置
KEEPALIVED_NODES=("10.18.1.27" "10.18.1.28")
VIP="10.18.1.30"

# MySQL 配置
MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"
MYSQL_PORT=3306

# 测试数据库配置
TEST_DB="ha_switch_test"
TEST_TABLE="consistency_data"
TEST_TABLE_SIZE=100000  # 初始数据量

# Sysbench 配置
SYSBENCH_THREADS=16
SYSBENCH_TIME=180  # 测试时间（秒）
SYSBENCH_RATE=500  # 每秒事务数

# 路径配置
LOG_DIR="/home/sder/ha/replica/scripts/mysql_ha_test/logs"
REPORT_DIR="/home/sder/ha/replica/scripts/mysql_ha_test/reports"
DATA_DIR="/home/sder/ha/replica/scripts/mysql_ha_test/data"

# 工具检查
command -v sysbench >/dev/null 2>&1 || {
    echo "请安装 sysbench: sudo apt install sysbench"
    exit 1
}

command -v mysql >/dev/null 2>&1 || {
    echo "请安装 mysql-client: sudo apt install mysql-client"
    exit 1
}

# 创建目录
mkdir -p $LOG_DIR $REPORT_DIR $DATA_DIR