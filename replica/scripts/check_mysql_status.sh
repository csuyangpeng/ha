#!/bin/bash
# keepalived vrrp_script 健康检查
#
# 约定（重要）：
#   MASTER（持有 VIP）：MySQL 不可用或不可写 -> exit 1，释放 VIP 触发切换；
#   BACKUP（未持有 VIP）：只记录/告警，始终 exit 0。若备节点返回失败会进入
#   FAULT 状态，反而无法在主库故障时接管。
source "/home/sder/ha/replica/scripts/base.sh"

MAIL_TO="peng.yang@kingsignal.com"

log() {
    echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# 限频日志：同一 key 每 interval 秒最多写一条
log_limited() {
    local key=$1 interval=$2 msg=$3 f now last
    f="/var/run/replica_log_${key}"
    now=$(date +%s)
    last=$(cat "$f" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$interval" ]; then
        echo "$now" > "$f"
        log "$msg"
    fi
}

send_notification() {
    local role=$1 level=$2 message=$3
    log "[$level] $message"
    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "Replica 告警 - ${LOCAL_IP} - ${role}" "$MAIL_TO"
    fi
}

# 限频告警：BACKUP 侧异常可能持续存在，避免每 5 秒发一次
notify_limited() {
    local key=$1 interval=$2 role=$3 level=$4 message=$5
    local f now last
    f="/var/run/replica_notify_${key}"
    now=$(date +%s)
    last=$(cat "$f" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$interval" ]; then
        echo "$now" > "$f"
        send_notification "$role" "$level" "$message"
    fi
}

# 提升进行中（持有 VIP 但仍只读属于正常过渡）
in_promotion() {
    [ -f "$PROMOTE_FLAG" ] || return 1
    local started age
    started=$(cat "$PROMOTE_FLAG" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - started ))
    [ "$age" -ge 0 ] && [ "$age" -lt 120 ]
}

# 从库重建：异步执行 + 限频，避免拖住 keepalived 的健康检查
schedule_restore() {
    local now last
    now=$(date +%s)
    last=$(cat "$RESTORE_TS_FILE" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$RESTORE_INTERVAL" ]; then
        log_limited restore_wait 300 "距上次重建不足 ${RESTORE_INTERVAL}s，跳过"
        return 0
    fi
    echo "$now" > "$RESTORE_TS_FILE"
    log "异步执行从库重建：$SCRIPT_DIR/restore_mysql_slave.sh"
    setsid "$SCRIPT_DIR/restore_mysql_slave.sh" >> "$LOG" 2>&1 < /dev/null &
}

main() {
    # 防止重叠执行；进程退出自动释放，不会像普通锁文件那样残留
    exec 9>"$LOCK_FILE" || exit 0
    flock -n 9 || { log "上一次检查仍在运行，跳过"; exit 0; }

    local role=MASTER
    is_on_vip || role=BACKUP

    # ---- MySQL 进程不可用 ----
    if ! mysql_alive; then
        log "MySQL 不可用（role=${role}）"
        if [ "$role" = "MASTER" ]; then
            send_notification "$role" "ERROR" "MySQL 不可用，释放 VIP 触发切换（${LOCAL_IP}）"
            exit 1
        fi
        exit 0
    fi

    if [ "$role" = "MASTER" ]; then
        local ro sro
        ro=$(mysql_query "SELECT @@global.read_only")
        sro=$(mysql_query "SELECT @@global.super_read_only")

        if [ "$ro" != "0" ] || [ "$sro" != "0" ]; then
            if in_promotion; then
                log_limited promotion 60 "提升进行中（read_only=${ro}），暂不判定失败"
                exit 0
            fi
            send_notification "$role" "ERROR" "MASTER 处于只读状态（read_only=${ro}, super_read_only=${sro}），释放 VIP"
            exit 1
        fi

        log_limited master_ok 300 "MASTER 检查通过（可写）"
        exit 0
    fi

    # ---- BACKUP：确保只读（SET GLOBAL 不持久，重启后会变回可写） ----
    # 应用当前用 root 连接，read_only=ON 挡不住 SUPER，必须 super_read_only=ON。
    # 从库重建（restore_mysql_slave.sh）需要用 root 导入，期间靠标记文件跳过。
    local restoring=0 ro sro flag_age
    if [ -f "${REPLICA_DIR}/.restoring" ]; then
        flag_age=$(( $(date +%s) - $(stat -c %Y "${REPLICA_DIR}/.restoring" 2>/dev/null || echo 0) ))
        [ "$flag_age" -lt 3600 ] && restoring=1
    fi
    if [ "$restoring" -eq 0 ]; then
        ro=$(mysql_query "SELECT @@global.read_only")
        sro=$(mysql_query "SELECT @@global.super_read_only")
        if [ "$ro" != "1" ] || [ "$sro" != "1" ]; then
            mysql_exec -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;" >/dev/null 2>&1
            log "BACKUP 只读状态异常（read_only=${ro:-?}, super_read_only=${sro:-?}），已修正"
        fi
    fi

    # ---- BACKUP：只看复制健康，不返回失败 ----
    local status io sql_r lag
    status=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -z "$status" ]; then
        notify_limited no_slave 300 "$role" "WARNING" "BACKUP 未配置复制关系（${LOCAL_IP}），准备重建"
        schedule_restore
        exit 0
    fi

    io=$(echo "$status" | awk -F': ' '/Slave_IO_Running:/{print $2}')
    sql_r=$(echo "$status" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
    lag=$(echo "$status" | awk -F': ' '/Seconds_Behind_Master:/{print $2}')

    if [ "$io" != "Yes" ] || [ "$sql_r" != "Yes" ]; then
        notify_limited repl_broken 300 "$role" "WARNING" "BACKUP 复制异常（IO=${io:-N/A}, SQL=${sql_r:-N/A}），准备重建"
        schedule_restore
        exit 0
    fi

    log_limited backup_ok 300 "BACKUP 检查通过（IO=${io}, SQL=${sql_r}, 延迟=${lag:-N/A}s）"
    exit 0
}

main
