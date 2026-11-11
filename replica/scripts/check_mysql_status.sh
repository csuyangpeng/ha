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
# LOG_UNLIMITED=1（base.sh）或存在 /var/run/replica_log_unlimited 时不限频
log_limited() {
    local key=$1 interval=$2 msg=$3 f now last
    if [ "${LOG_UNLIMITED:-0}" = "1" ] || [ -e /var/run/replica_log_unlimited ]; then
        log "$msg"
        return
    fi
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

# 降级进行中（notify_slave 正在重建复制关系，复制短暂为空/异常属正常过渡）
in_demotion() {
    [ -f "$DEMOTE_FLAG" ] || return 1
    local started age
    started=$(cat "$DEMOTE_FLAG" 2>/dev/null || echo 0)
    age=$(( $(date +%s) - started ))
    [ "$age" -ge 0 ] && [ "$age" -lt 120 ]
}

# 从库重建：异步执行 + 限频，避免拖住 keepalived 的健康检查
schedule_restore() {
    local now last
    # 已有重建在进行（手动或自动）就不再拉起第二个；
    # 锁由 restore_mysql_slave.sh 持有，这里只探测不抢占。
    if [ -e "$RESTORE_LOCK_FILE" ] && ! flock -n "$RESTORE_LOCK_FILE" true 2>/dev/null; then
        log_limited restore_busy 300 "已有重建在进行，跳过本次调度"
        return 0
    fi
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

# ---- BACKUP 复制异常的处置 ----
# 顺序：数据级错误直接重建；其余先做轻量修复（重新指向 VIP + 启动复制），
# 每 15s 最多一次，连续 3 次仍失败才允许全量重建。
# 典型收益：MySQL 重启后复制配置丢失/指向错误，几秒就能恢复，不必清库重建。
REPAIR_MAX_ATTEMPTS=3
REPAIR_MIN_INTERVAL=15

repair_replication() {
    mysql_exec >/dev/null 2>&1 <<EOF
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='${MYSQL_VIP}',
  MASTER_USER='${MYSQL_USER}',
  MASTER_PASSWORD='${MYSQL_PASS}',
  MASTER_PORT=${MYSQL_PORT},
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
START SLAVE;
EOF
}

is_data_level_error() {
    printf '%s' "$1" | grep -qiE 'Error_code: ?(1032|1049|1062|1146|1236|1837)|purged|gtid|duplicate entry|unknown database|doesn.t exist'
}

handle_replication_problem() {   # $1=role $2=简述 $3=Last_IO/SQL_Error 文本
    local role=$1 desc=$2 err=$3 now last cnt
    if is_data_level_error "$err"; then
        notify_limited repl_rebuild 300 "$role" "ERROR" "BACKUP 复制数据级损坏（${desc}），准备全量重建"
        rm -f "$REPAIR_CNT_FILE" "$REPAIR_TS_FILE" 2>/dev/null || true
        schedule_restore
        return 0
    fi

    now=$(date +%s)
    last=$(cat "$REPAIR_TS_FILE" 2>/dev/null || echo 0)
    cnt=$(cat "$REPAIR_CNT_FILE" 2>/dev/null || echo 0)
    case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac

    if [ $((now - last)) -lt "$REPAIR_MIN_INTERVAL" ]; then
        log_limited repair_wait 15 "BACKUP 复制异常（${desc}），等待轻量修复结果（${cnt}/${REPAIR_MAX_ATTEMPTS}）"
        return 0
    fi

    notify_limited repl_repair 300 "$role" "WARNING" "BACKUP 复制异常（${desc}），先尝试轻量修复（重新指向 VIP）"
    echo "$now" > "$REPAIR_TS_FILE" 2>/dev/null || true
    cnt=$((cnt + 1))
    echo "$cnt" > "$REPAIR_CNT_FILE" 2>/dev/null || true
    repair_replication
    log "BACKUP 复制异常（${desc}），已重新指向 VIP ${MYSQL_VIP} 并启动复制（${cnt}/${REPAIR_MAX_ATTEMPTS}）"
    [ "$cnt" -lt "$REPAIR_MAX_ATTEMPTS" ] && return 0

    notify_limited repl_rebuild 300 "$role" "ERROR" "BACKUP 复制异常（${desc}），轻量修复 ${cnt} 次无效，准备全量重建"
    rm -f "$REPAIR_CNT_FILE" "$REPAIR_TS_FILE" 2>/dev/null || true
    schedule_restore
}

# 依赖上面定义的日志/告警/提升判定函数，放在 main 之前 source
source "/home/sder/ha/replica/scripts/check_core_status.sh"

main() {
    # 防止重叠执行；进程退出自动释放，不会像普通锁文件那样残留
    exec 9>"$LOCK_FILE" || exit 0
    flock -n 9 || { log "上一次检查仍在运行，跳过"; exit 0; }

    local role=MASTER
    is_on_vip || role=BACKUP

    [ "$role" = "BACKUP" ] && core_gate_backup

    # ---- MySQL 进程不可用 ----
    if ! mysql_alive; then
        log "MySQL 不可用（role=${role}）"
        if [ "$role" = "MASTER" ]; then
            if core_peer_ready_for_failover; then
                send_notification "$role" "ERROR" "MySQL 不可用，释放 VIP 触发切换（${LOCAL_IP}）"
                exit 1
            fi
            exit 0
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

        # 核心网关键网元异常且对端就绪时才释放 VIP
        core_gate_master || exit 1
        exit 0
    fi

    # ---- BACKUP：确保只读（SET GLOBAL 不持久，重启后会变回可写） ----
    # 应用当前用 root 连接，read_only=ON 挡不住 SUPER，必须 super_read_only=ON。
    # 从库重建（restore_mysql_slave.sh）需要用 root 导入，期间靠标记文件跳过。
    local restoring=0 ro sro flag_age flag_pid
    if [ -f "${REPLICA_DIR}/.restoring" ]; then
        flag_age=$(( $(date +%s) - $(stat -c %Y "${REPLICA_DIR}/.restoring" 2>/dev/null || echo 0) ))
        flag_pid=$(tr -dc '0-9' < "${REPLICA_DIR}/.restoring" 2>/dev/null)
        if [ -n "$flag_pid" ] && kill -0 "$flag_pid" 2>/dev/null; then
            # 标记里的 PID 还活着才算重建进行中（进程被 kill -9 时 trap 不会执行）
            [ "$flag_age" -lt 7200 ] && restoring=1
        else
            # 旧格式（无 PID）或进程已退出：按新鲜度兜底
            [ "$flag_age" -lt 3600 ] && restoring=1
        fi
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
    local status io sql_r lag err
    status=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -z "$status" ]; then
        if in_demotion; then
            log_limited demoting 30 "BACKUP 降级进行中（尚未配置复制），跳过重建"
            exit 0
        fi
        if [ "$restoring" -eq 1 ]; then
            log_limited restore_running 30 "从库重建进行中，跳过复制检查"
            exit 0
        fi
        log "BACKUP 未配置复制关系（${LOCAL_IP}）"
        handle_replication_problem "$role" "未配置复制关系" ""
        exit 0
    fi

    io=$(echo "$status" | awk -F': ' '/Slave_IO_Running:/{print $2}')
    sql_r=$(echo "$status" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
    lag=$(echo "$status" | awk -F': ' '/Seconds_Behind_Master:/{print $2}')

    if [ "$io" != "Yes" ] || [ "$sql_r" != "Yes" ]; then
        if in_demotion; then
            log_limited demoting 30 "BACKUP 降级进行中（IO=${io:-N/A}, SQL=${sql_r:-N/A}），跳过重建"
            exit 0
        fi
        if [ "$restoring" -eq 1 ]; then
            log_limited restore_running 30 "从库重建进行中，跳过复制检查"
            exit 0
        fi
        err=$(echo "$status" | awk -F': ' '/Last_IO_Error:|Last_SQL_Error:/{print}')
        handle_replication_problem "$role" "IO=${io:-N/A}, SQL=${sql_r:-N/A}" "$err"
        exit 0
    fi

    rm -f "$REPAIR_CNT_FILE" "$REPAIR_TS_FILE" 2>/dev/null || true
    log_limited backup_ok 300 "BACKUP 检查通过（IO=${io}, SQL=${sql_r}, 延迟=${lag:-N/A}s）"
    exit 0
}

main
