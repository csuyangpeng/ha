#!/bin/bash
# /etc/keepalived/scripts/check_mysql_status.sh

source /home/sder/ha/replica/scripts/base.sh

# 获取当前 Keepalived 状态
get_keepalived_role() {
    if ip addr show ens3 | grep -q "10.18.1.30"; then
        echo "MASTER"
    else
        echo "SLAVE"
    fi
}

# 检查 MySQL 连接
check_mysql_connect() {
    docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT 1;" 2>&1 | _ts_pipe >> "$LOG"

    if docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT 1;" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查 MySQL 主库状态
check_mysql_master() {
    READ_ONLY=$(docker exec -i mysql mysql -uroot -p's<9!Own1z4' -N -e "SELECT @@global.read_only;" 2>/dev/null)
    if [ "$READ_ONLY" = "0" ]; then
        echo "MySQL 主库状态正常（可写）" 2>&1 | _ts_pipe >> "$LOG"
        return 0
    else
        echo "MySQL 主库异常：处于只读状态" 2>&1 | _ts_pipe >> "$LOG"
        return 1
    fi
}

# 检查 MySQL 从库状态
check_mysql_slave() {
    SLAVE_STATUS=$(docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "无法获取从库状态" 2>&1 | _ts_pipe >> "$LOG"
        return 1
    fi
    
    # 检查复制是否运行
    IO_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_IO_Running:" | awk '{print $2}')
    SQL_RUNNING=$(echo "$SLAVE_STATUS" | grep "Slave_SQL_Running:" | awk '{print $2}')
    SECONDS_BEHIND=$(echo "$SLAVE_STATUS" | grep "Seconds_Behind_Master:" | awk '{print $2}')

    if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
        echo "MySQL 从库状态正常（IO: $IO_RUNNING, SQL: $SQL_RUNNING, 延迟: ${SECONDS_BEHIND:-N/A}秒）" 2>&1 | _ts_pipe >> "$LOG"
        return 0
    else
        echo "MySQL 从库异常：IO_Running=$IO_RUNNING, SQL_Running=$SQL_RUNNING" 2>&1 | _ts_pipe >> "$LOG"
        return 1
    fi
}

# 发送通知
send_notification() {
    local role=$1
    local status=$2
    local message=$3
    
    # 邮件通知
    echo "$message" | mail -s "Keepalived MySQL 告警 - $(hostname) - $role" peng.yang@kingsignal.com
    
    # 日志记录
    echo "通知已发送：$message" 2>&1 | _ts_pipe >> "$LOG"
    
    # 也可以集成到其他告警系统
    # curl -X POST https://your-webhook.url -d "{\"message\":\"$message\"}"
}

# 主逻辑

main() {
  # sleep 15
  {
    if [ -f "$LOCK_FILE" ]; then
        echo "[LINE:$LINENO]另一个备份任务正在运行，跳过本次备份" 2>&1 | _ts_pipe >> "$LOG"
        exit 0
    fi

    touch "$LOCK_FILE"
    echo "[LINE:$LINENO]create $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"

    # 读取 LOCK_FILE 的内容
    if [ -f "$THRESHOLD_FILE" ]; then
        COUNT=$(cat "$THRESHOLD_FILE")
    else
        echo "0" > "$THRESHOLD_FILE"
        rm -f "$LOCK_FILE"
        echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"
        exit 0
    fi

    if [ "$COUNT" -lt "$THRESHOLD" ]; then        
        echo "[LINE:$LINENO]当前阈值计数为 $COUNT，未达到执行条件，跳过本次检查" 2>&1 | _ts_pipe >> "$LOG"
        COUNT=$((COUNT + 1))
        echo "$COUNT" > "$THRESHOLD_FILE"
        rm -f "$LOCK_FILE"
        echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"
        exit 0
    else
        # 达到阈值，重置计数
        echo "0" > "$THRESHOLD_FILE"
        echo "[LINE:$LINENO]达到阈值计数 $THRESHOLD， 执行检查" 2>&1 | _ts_pipe >> "$LOG"
    fi

    ROLE=$(get_keepalived_role)
    
    # 检查 MySQL 连接
    if ! check_mysql_connect; then
        echo "[LINE:$LINENO]MySQL 连接失败" 2>&1 | _ts_pipe >> "$LOG"
        if [ "$ROLE" = "MASTER" ]; then
            send_notification "$ROLE" "ERROR" "MySQL 连接失败！VIP: 10.18.1.30，主机: $(hostname)"
        fi
        rm -f "$LOCK_FILE"
        echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"
        exit 0
    fi
    
    # 根据角色检查不同状态
    if [ "$ROLE" = "MASTER" ]; then
        if ! check_mysql_master; then
            send_notification "$ROLE" "WARNING" "MySQL 主库状态异常！可能处于只读模式"
            rm -f "$LOCK_FILE"
            echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"
            exit 0
        fi
    else
        if ! check_mysql_slave; then
            echo "[LINE:$LINENO]从库复制异常，准备执行恢复脚本" 2>&1 | _ts_pipe >> "$LOG"
            /home/sder/ha/replica/scripts/restore_mysql_slave.sh
            rm -f "$LOCK_FILE"   
            echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"     
            exit 0
        fi
    fi
    
    echo "[LINE:$LINENO]MySQL 状态检查通过，角色: $ROLE" 2>&1 | _ts_pipe >> "$LOG"
    rm -f "$LOCK_FILE"
    echo "[LINE:$LINENO]remove $LOCK_FILE" 2>&1 | _ts_pipe >> "$LOG"
    exit 0
  }
  exit 0
}

# 运行主逻辑
main