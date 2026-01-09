#!/bin/bash
# 执行主库切换测试

source ./config.sh

echo "=== 执行主库切换测试 ==="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 获取当前主库
get_current_master() {
    for node in "${KEEPALIVED_NODES[@]}"; do
        if mysql -h $node -u $MYSQL_USER -p$MYSQL_PASS -e "SHOW SLAVE STATUS" 2>/dev/null | grep -q "Master_Host"; then
            echo $node
            return
        fi
    done
    # 如果没有找到从库，那么第一个节点就是主库
    echo ${KEEPALIVED_NODES[0]}
}

CURRENT_MASTER=$(get_current_master)
BACKUP_NODE=""
for node in "${KEEPALIVED_NODES[@]}"; do
    if [ "$node" != "$CURRENT_MASTER" ]; then
        BACKUP_NODE=$node
        break
    fi
done

echo "当前主库: $CURRENT_MASTER"
echo "备份节点: $BACKUP_NODE"

# 记录切换前状态
echo "1. 记录切换前状态..."
BEFORE_CHECKPOINT_ID=$(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -N -e \
    "SELECT checkpoint_id FROM switch_checkpoint ORDER BY checkpoint_id DESC LIMIT 1")

# 启动sysbench压力测试（后台运行）
echo "2. 启动sysbench压力测试..."
sysbench oltp_write_only \
    --db-driver=mysql \
    --mysql-host=$VIP \
    --mysql-port=$MYSQL_PORT \
    --mysql-user=$MYSQL_USER \
    --mysql-password=$MYSQL_PASS \
    --mysql-db=$TEST_DB \
    --table-size=$TEST_TABLE_SIZE \
    --tables=1 \
    --threads=$SYSBENCH_THREADS \
    --time=$SYSBENCH_TIME \
    --rate=$SYSBENCH_RATE \
    --report-interval=5 \
    --mysql-ignore-errors=all \
    run > $LOG_DIR/sysbench_during_switch.log 2>&1 &
    
SYSBENCH_PID=$!
echo "Sysbench PID: $SYSBENCH_PID"

# 等待sysbench稳定运行
sleep 10

# 触发切换
echo "3. 触发Keepalived切换..."
SWITCH_TIME=$(date +%s)

# 方法1: 停止当前主库的keepalived服务
echo "停止 $CURRENT_MASTER 上的keepalived服务..."
ssh $CURRENT_MASTER "sudo systemctl stop keepalived"

# 方法2: 或者直接关闭MySQL（更真实的故障模拟）
# echo "模拟MySQL故障..."
# ssh $CURRENT_MASTER "sudo systemctl stop mysql"

# 等待VIP切换
echo "等待VIP切换 (最多30秒)..."
for i in {1..30}; do
    sleep 1
    # 尝试连接新主库
    if mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT 1" 2>/dev/null; then
        NEW_MASTER=$(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT @@hostname" 2>/dev/null | tr -d '\n')
        for node in "${KEEPALIVED_NODES[@]}"; do
            if ssh $node "hostname" 2>/dev/null | grep -q "$NEW_MASTER"; then
                ACTUAL_NEW_MASTER=$node
                break
            fi
        done
        echo "VIP切换完成! 新主库: $ACTUAL_NEW_MASTER"
        break
    fi
    echo -n "."
done

# 记录切换时间
SWITCH_DURATION=$(( $(date +%s) - $SWITCH_TIME ))
echo "切换耗时: ${SWITCH_DURATION}秒"

# 等待sysbench压力测试完成
echo "等待sysbench测试完成..."
wait $SYSBENCH_PID
echo "压力测试完成"

# 记录切换后状态
echo "4. 记录切换后状态..."
mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB <<EOF
INSERT INTO switch_checkpoint 
    (node_host, node_ip, table_name, total_rows, max_id, min_id, total_amount, avg_balance, extra_info)
SELECT 
    @@hostname,
    '$ACTUAL_NEW_MASTER',
    '$TEST_TABLE',
    COUNT(*),
    COALESCE(MAX(id), 0),
    COALESCE(MIN(id), 0),
    SUM(amount),
    AVG(balance),
    JSON_OBJECT(
        'switch_time', '$SWITCH_TIME',
        'switch_duration', '$SWITCH_DURATION',
        'old_master', '$CURRENT_MASTER',
        'sysbench_threads', '$SYSBENCH_THREADS',
        'sysbench_rate', '$SYSBENCH_RATE'
    )
FROM $TEST_TABLE;
EOF

echo "切换测试完成!"