#!/bin/bash
# 监控切换过程

source ./config.sh

echo "=== 切换过程监控 ==="
echo "开始监控: $(date '+%Y-%m-%d %H:%M:%S')"

# 监控文件
MONITOR_LOG="$LOG_DIR/monitor_$(date +%Y%m%d_%H%M%S).log"

# 监控函数
monitor_mysql_status() {
    local host=$1
    local label=$2
    
    echo "[$(date '+%H:%M:%S')] $label ($host):" | tee -a $MONITOR_LOG
    
    # 检查MySQL服务状态
    if ssh $host "systemctl is-active mysql" 2>/dev/null | grep -q "active"; then
        echo "  MySQL状态: ✅ 运行中" | tee -a $MONITOR_LOG
        
        # 获取MySQL状态信息
        ssh $host "mysql -u $MYSQL_USER -p$MYSQL_PASS -e '
            SELECT 
                \"连接数:\" AS metric,
                COUNT(*) AS value 
            FROM information_schema.PROCESSLIST 
            UNION ALL
            SELECT 
                \"QPS:\",
                VARIABLE_VALUE 
            FROM performance_schema.global_status 
            WHERE VARIABLE_NAME = \"QUERIES\" 
            UNION ALL
            SELECT 
                \"活动事务:\",
                COUNT(*) 
            FROM information_schema.INNODB_TRX'" 2>/dev/null | tee -a $MONITOR_LOG
    else
        echo "  MySQL状态: ❌ 停止" | tee -a $MONITOR_LOG
    fi
    
    # 检查Keepalived状态
    if ssh $host "systemctl is-active keepalived" 2>/dev/null | grep -q "active"; then
        echo "  Keepalived: ✅ 运行中" | tee -a $MONITOR_LOG
        ssh $host "ip addr show | grep $VIP" 2>/dev/null | tee -a $MONITOR_LOG
    else
        echo "  Keepalived: ❌ 停止" | tee -a $MONITOR_LOG
    fi
    
    echo "" | tee -a $MONITOR_LOG
}

# 持续监控
echo "开始持续监控 (按Ctrl+C停止)..." | tee -a $MONITOR_LOG
while true; do
    echo "========================================" | tee -a $MONITOR_LOG
    for node in "${KEEPALIVED_NODES[@]}"; do
        monitor_mysql_status $node "节点"
    done
    
    # 检查VIP连接
    echo "[$(date '+%H:%M:%S')] VIP连接测试 ($VIP):" | tee -a $MONITOR_LOG
    if timeout 2 mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT 1" 2>/dev/null; then
        echo "  VIP连接: ✅ 正常" | tee -a $MONITOR_LOG
        # 获取通过VIP连接的实际主机
        REAL_HOST=$(timeout 2 mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT @@hostname" 2>/dev/null | tr -d '\n')
        echo "  实际主机: $REAL_HOST" | tee -a $MONITOR_LOG
    else
        echo "  VIP连接: ❌ 失败" | tee -a $MONITOR_LOG
    fi
    
    sleep 5
done