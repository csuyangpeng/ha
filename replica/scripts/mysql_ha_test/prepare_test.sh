#!/bin/bash
# 准备测试环境和数据

source ./config.sh

echo "=== MySQL HA 测试准备阶段 ==="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 函数：检查MySQL连接
check_mysql_connection() {
    local host=$1
    echo "检查MySQL连接: $host"
    mysql -h $host -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT 1" 2>/dev/null
    return $?
}

# 确定当前主库（通过VIP）
echo "1. 确定当前主库..."
CURRENT_MASTER=""
for node in "${KEEPALIVED_NODES[@]}"; do
    if mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT @@server_id" 2>/dev/null | grep -q .; then
        # 通过实际连接确定后端节点
        REAL_HOST=$(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT @@hostname" 2>/dev/null)
        for n in "${KEEPALIVED_NODES[@]}"; do
            if ssh $n "hostname" 2>/dev/null | grep -q "$REAL_HOST"; then
                CURRENT_MASTER=$n
                break 2
            fi
        done
    fi
done

if [ -z "$CURRENT_MASTER" ]; then
    echo "错误: 无法确定当前主库"
    exit 1
fi

echo "当前主库: $CURRENT_MASTER"

# 创建测试数据库
echo "2. 创建测试数据库..."
mysql -h $CURRENT_MASTER -u $MYSQL_USER -p$MYSQL_PASS <<EOF
DROP DATABASE IF EXISTS $TEST_DB;
CREATE DATABASE $TEST_DB;
USE $TEST_DB;

CREATE TABLE $TEST_TABLE (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    account_id INT UNSIGNED NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    balance DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    tx_time TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    tx_hash VARCHAR(64) NOT NULL,
    status TINYINT NOT NULL DEFAULT 0,
    remark VARCHAR(255),
    INDEX idx_account (account_id),
    INDEX idx_time (tx_time),
    UNIQUE KEY uk_hash (tx_hash(32))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;

-- 创建检查点表
CREATE TABLE IF NOT EXISTS switch_checkpoint (
    checkpoint_id INT AUTO_INCREMENT PRIMARY KEY,
    checkpoint_time TIMESTAMP(6) DEFAULT CURRENT_TIMESTAMP(6),
    node_host VARCHAR(100),
    node_ip VARCHAR(15),
    table_name VARCHAR(64),
    total_rows BIGINT,
    max_id BIGINT,
    min_id BIGINT,
    total_amount DECIMAL(20,2),
    avg_balance DECIMAL(15,2),
    extra_info JSON
);
EOF

# 记录初始检查点
echo "3. 记录初始检查点..."
mysql -h $CURRENT_MASTER -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB <<EOF
INSERT INTO switch_checkpoint 
    (node_host, node_ip, table_name, total_rows, max_id, min_id, total_amount, avg_balance)
SELECT 
    @@hostname,
    '$CURRENT_MASTER',
    '$TEST_TABLE',
    0,
    0,
    0,
    0.00,
    0.00
FROM DUAL;
EOF

# 准备sysbench测试数据
echo "4. 准备sysbench测试数据..."
sysbench oltp_read_write \
    --db-driver=mysql \
    --mysql-host=$VIP \
    --mysql-port=$MYSQL_PORT \
    --mysql-user=$MYSQL_USER \
    --mysql-password=$MYSQL_PASS \
    --mysql-db=$TEST_DB \
    --table-size=$TEST_TABLE_SIZE \
    --tables=1 \
    --threads=4 \
    --time=30 \
    prepare > $LOG_DIR/sysbench_prepare.log 2>&1

echo "准备完成! 初始数据量: $TEST_TABLE_SIZE 行"
echo "VIP: $VIP"
echo "主库节点: $CURRENT_MASTER"