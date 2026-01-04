#!/bin/bash
# 简单直接的HA测试脚本

# 基础配置
NODE1="10.18.1.27"
NODE2="10.18.1.28"
VIP="10.18.1.30"
MYSQL_USER="root"
MYSQL_PASSWORD="s<9!Own1z4"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查哪个节点有VIP
check_vip_location() {
    log "检查VIP位置..."
    
    if ssh $NODE1 "ip addr show | grep -q '$VIP'" 2>/dev/null; then
        echo "$NODE1"
        log "VIP在节点1 ($NODE1)"
    elif ssh $NODE2 "ip addr show | grep -q '$VIP'" 2>/dev/null; then
        echo "$NODE2"
        log "VIP在节点2 ($NODE2)"
    else
        echo ""
        log "警告: 未找到VIP"
    fi
}

# 检查MySQL容器状态
check_mysql_container() {
    local node=$1
    log "检查节点 $node 的MySQL容器..."
    
    if ssh $node "docker ps --format '{{.Names}}' | grep mysql" 2>/dev/null; then
        log "✓ 节点 $node: MySQL容器运行中"
        return 0
    else
        log "✗ 节点 $node: MySQL容器未运行"
        return 1
    fi
}

# 检查MySQL连接
check_mysql_connect() {
    local host=$1
    local node=$2
    
    log "检查MySQL连接 (主机: $host, 节点: $node)..."
    
    # 通过docker exec在容器内执行
    if ssh $node "docker exec mysql mysql -h $host -u $MYSQL_USER -p'$MYSQL_PASSWORD' -e 'SELECT 1'" 2>/dev/null; then
        log "✓ MySQL连接正常"
        return 0
    else
        log "✗ MySQL连接失败"
        return 1
    fi
}

# 检查MySQL角色
check_mysql_role() {
    local node=$1
    
    log "检查节点 $node 的MySQL角色..."
    
    local result=$(ssh $node "docker exec mysql mysql -u $MYSQL_USER -p'$MYSQL_PASSWORD' -e 'SHOW SLAVE STATUS\G' 2>/dev/null | wc -l")
    
    if [ $result -eq 0 ]; then
        echo "MASTER"
        log "节点 $node 是主库"
    else
        echo "SLAVE"
        log "节点 $node 是从库"
        
        # 显示复制状态
        local slave_status=$(ssh $node "docker exec mysql mysql -u $MYSQL_USER -p'$MYSQL_PASSWORD' -e 'SHOW SLAVE STATUS\G'" 2>/dev/null)
        echo "$slave_status" | grep -E "(Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master)" | head -3
    fi
}

# 测试数据写入
test_data_write() {
    local node=$1
    local test_data="test_$(date +%s)"
    
    log "在节点 $node 测试数据写入..."
    
    if ssh $node "docker exec mysql mysql -u $MYSQL_USER -p'$MYSQL_PASSWORD' -e \"
        CREATE DATABASE IF NOT EXISTS ha_test;
        USE ha_test;
        CREATE TABLE IF NOT EXISTS test_table (
            id INT AUTO_INCREMENT PRIMARY KEY,
            data VARCHAR(255),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        INSERT INTO test_table (data) VALUES ('$test_data');
    \"" 2>/dev/null; then
        log "✓ 数据写入成功: $test_data"
        return 0
    else
        log "✗ 数据写入失败"
        return 1
    fi
}

# 测试VIP切换
test_vip_switch() {
    log "=== 开始VIP切换测试 ==="
    
    # 1. 检查当前VIP位置
    current_vip=$(check_vip_location)
    if [ -z "$current_vip" ]; then
        log "无法继续测试: 未找到VIP"
        return 1
    fi
    
    # 2. 确定目标节点
    if [ "$current_vip" = "$NODE1" ]; then
        target_node=$NODE2
    else
        target_node=$NODE1
    fi
    
    log "当前VIP在: $current_vip, 目标切换节点: $target_node"
    
    # 3. 停止当前节点的keepalived
    log "停止 $current_vip 的keepalived..."
    ssh $current_vip "sudo systemctl stop keepalived"
    
    # 4. 等待切换
    log "等待VIP切换 (10秒)..."
    sleep 10
    
    # 5. 检查新VIP位置
    new_vip=$(check_vip_location)
    if [ "$new_vip" = "$target_node" ]; then
        log "✓ VIP切换成功: $current_vip -> $target_node"
        
        # 6. 恢复服务
        log "恢复 $current_vip 的keepalived..."
        ssh $current_vip "sudo systemctl start keepalived"
        sleep 5
        
        # 7. 检查是否保持（nopreempt）
        final_vip=$(check_vip_location)
        if [ "$final_vip" = "$target_node" ]; then
            log "✓ nopreempt生效，VIP保持在 $target_node"
        else
            log "注意: VIP回到了 $final_vip"
        fi
        
        return 0
    else
        log "✗ VIP切换失败，当前在: $new_vip"
        ssh $current_vip "sudo systemctl start keepalived"
        return 1
    fi
}

# 测试MySQL故障切换
test_mysql_failover() {
    log "=== 开始MySQL故障切换测试 ==="
    
    # 1. 确定当前主库
    current_master=""
    for node in $NODE1 $NODE2; do
        role=$(check_mysql_role $node)
        if [ "$role" = "MASTER" ]; then
            current_master=$node
            break
        fi
    done
    
    if [ -z "$current_master" ]; then
        log "无法确定主库"
        return 1
    fi
    
    log "当前主库: $current_master"
    
    # 2. 停止主库MySQL容器
    log "停止 $current_master 的MySQL容器..."
    ssh $current_master "docker stop mysql"
    
    # 3. 等待切换
    log "等待故障切换 (15秒)..."
    sleep 15
    
    # 4. 检查VIP是否切换
    new_vip=$(check_vip_location)
    if [ "$new_vip" != "$current_master" ]; then
        log "✓ VIP已切换到: $new_vip"
        
        # 5. 检查新主库是否可写
        if test_data_write $new_vip; then
            log "✓ 新主库可写"
        else
            log "✗ 新主库写入失败"
        fi
        
        # 6. 恢复原主库
        log "恢复 $current_master 的MySQL容器..."
        ssh $current_master "docker start mysql"
        sleep 10
        
        # 7. 检查原主库角色
        recovered_role=$(check_mysql_role $current_master)
        log "原主库恢复后角色: $recovered_role"
        
        return 0
    else
        log "✗ VIP未切换，仍在 $new_vip"
        ssh $current_master "docker start mysql"
        return 1
    fi
}

# 完整测试套件
run_full_test() {
    log "========================================="
    log "开始HA集群完整测试"
    log "测试时间: $(date)"
    log "========================================="
    
    echo ""
    log "1. 基础状态检查"
    echo "--------------"
    
    # 检查VIP
    vip_location=$(check_vip_location)
    
    # 检查容器状态
    check_mysql_container $NODE1
    check_mysql_container $NODE2
    
    # 检查MySQL角色
    role1=$(check_mysql_role $NODE1)
    role2=$(check_mysql_role $NODE2)
    
    echo ""
    log "2. 连接测试"
    echo "--------------"
    
    # 通过VIP连接测试
    vip_node=$vip_location
    if [ -n "$vip_node" ]; then
        check_mysql_connect $VIP $vip_node
    fi
    
    echo ""
    log "3. VIP切换测试"
    echo "--------------"
    test_vip_switch
    
    echo ""
    log "4. MySQL故障切换测试"
    echo "-------------------"
    test_mysql_failover
    
    echo ""
    log "========================================="
    log "测试完成"
    log "========================================="
}

# 快速检查模式
quick_check() {
    log "=== HA集群快速检查 ==="
    
    echo "VIP状态:"
    vip=$(check_vip_location)
    echo "  VIP位置: ${vip:-未找到}"
    
    echo ""
    echo "节点状态:"
    for node in $NODE1 $NODE2; do
        echo "节点 $node:"
        
        # 容器状态
        if ssh $node "docker ps --format '{{.Names}}' | grep -q mysql" 2>/dev/null; then
            echo "  ✓ MySQL容器: 运行中"
            
            # MySQL状态
            if ssh $node "docker exec mysql mysql -u $MYSQL_USER -p'$MYSQL_PASSWORD' -e 'SELECT 1'" 2>/dev/null; then
                echo "  ✓ MySQL服务: 正常"
                
                # 角色
                role=$(check_mysql_role $node)
                echo "  ✓ MySQL角色: $role"
            else
                echo "  ✗ MySQL服务: 异常"
            fi
        else
            echo "  ✗ MySQL容器: 未运行"
        fi
        echo ""
    done
}

# 根据参数执行
case "$1" in
    "full")
        run_full_test
        ;;
    "vip")
        test_vip_switch
        ;;
    "mysql")
        test_mysql_failover
        ;;
    "check"|"")
        quick_check
        ;;
    *)
        echo "用法: $0 [full|vip|mysql|check]"
        echo "  full   完整测试"
        echo "  vip    VIP切换测试"
        echo "  mysql  MySQL故障切换测试"
        echo "  check  快速检查（默认）"
        ;;
esac
