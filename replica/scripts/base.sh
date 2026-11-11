#!/bin/bash
# replica 主备公共定义，被 keepalived 的 notify / track 脚本 source

_ts_pipe() {
  while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%a %b %d %I:%M:%S %p %Z %Y'):" "$line"
  done
}

# ---- 路径 ----
REPLICA_DIR="/home/sder/ha/replica"
LOG_DIR="$REPLICA_DIR/logs"
SCRIPT_DIR="$REPLICA_DIR/scripts"
LOG="$LOG_DIR/keepalived-wrapper.log"

# 日志目录可能在首次部署/清空数据后被删掉；notify/track 脚本以 root 运行，可直接创建
mkdir -p "$LOG_DIR" 2>/dev/null || true

# ---- 网络 ----
IFACE="ens3"
# 整组漂移的 VIP；第 1 个是数据面 VIP（MySQL/Redis/etcdvip 客户端使用）。
# deploy_cluster.sh 会按 --vip-list 重写这一行。
VIPS=("10.18.1.30")
MYSQL_VIP="${VIPS[0]%/*}"
NODE1="10.18.1.27"
NODE2="10.18.1.28"

LOCAL_IP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fx -e "$NODE1" -e "$NODE2" | head -1)
[ -n "$LOCAL_IP" ] || LOCAL_IP=$(hostname -I | awk '{print $1}')

# ---- coremgr / 核心网健康 ----
COREMGR_PORT=8888
COREMGR_HEALTH_URL=""                       # 留空则用 http://<peer>:$COREMGR_PORT/coremgr/ha/health
NF_HEALTH_FILE="/var/run/coremgr_nf_health"
CORE_GATE=1                                 # MASTER 的 core 健康是否参与释放 VIP
CORE_PEER_GATE_MYSQL=1                      # MySQL 硬故障时是否要求对端 core 就绪

# ---- 凭据 ----
MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"
MYSQL_PORT=3306

REDIS_PASS="A8K5h7+6!?"
REDIS_PORT=6379

# ---- 日志 ----
# 1 = 不限频：所有检查结果都落日志（排障期默认打开，重启后依然生效）。
# 告警邮件仍由 notify_limited 限频，不受此开关影响。
LOG_UNLIMITED=1

# ---- 运行时文件 ----
LOCK_FILE="/var/run/replica_health_check.lock"
RESTORE_TS_FILE="/var/run/replica_restore_last"
# 自动重建最小间隔（秒）。只约束健康检查的自动调度，手动执行 restore 不受影响。
# 复制真损坏时避免每 5 秒反复拉起重建；需要连续压测可临时置 0。
RESTORE_INTERVAL=120
# 从库重建方式：
#   clone（默认）= MySQL clone 插件物理克隆，秒级完成，不产生新 server_uuid/
#                  初始化事务，重建后的第一次倒换不再等待大事务；失败自动回退 dump。
#   dump         = mysqldump 逻辑导出（跨版本/跨环境可用）。
# 可用环境变量覆盖：RESTORE_MODE=dump ./restore_mysql_slave.sh
RESTORE_MODE="${RESTORE_MODE:-clone}"
# donor 侧克隆账号（BACKUP_ADMIN）；restore 脚本每次会自动创建/修正，无需手工维护。
CLONE_USER="cloneuser"
CLONE_PASS="Clone#R3pl1ca"
# 手动/自动重建互斥锁；restore_mysql_slave.sh 持锁，健康检查据此避免重复拉起
RESTORE_LOCK_FILE="/var/run/replica_restore.lock"
# BACKUP 复制异常的轻量修复状态：先重指 VIP 重启复制，连续失败才全量重建
REPAIR_CNT_FILE="/var/run/replica_repair_count"
REPAIR_TS_FILE="/var/run/replica_repair_last"
PROMOTE_FLAG="/var/run/replica_promoting"   # 提升进行中标记，避免健康检查误判
DEMOTE_FLAG="/var/run/replica_demoting"     # 降级进行中标记，避免健康检查误触发从库重建

# ---- 常用封装 ----
mysql_exec() {   # mysql_exec -e "SQL"  /  mysql_exec < file.sql；stderr 保留给调用方处理
    docker exec -i mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$@"
}

mysql_query() {  # mysql_query "SQL"  -> 无表头单列结果
    docker exec -i mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -N -e "$1" 2>/dev/null
}

mysql_alive() {
    docker exec -i mysql mysqladmin -u"$MYSQL_USER" -p"$MYSQL_PASS" ping >/dev/null 2>&1
}

redis_cli() {
    docker exec -i redis redis-cli -a "$REDIS_PASS" "$@" 2>/dev/null
}

# ---- VIP 判定 ----
bare_vip() { echo "${1%%/*}"; }

holds_vip() {   # holds_vip 10.18.1.31[/24]
    local ip=${1%%/*}
    ip addr show dev "$IFACE" 2>/dev/null | grep -q "inet ${ip}/"
}

held_vip_count() {
    local v n=0
    for v in "${VIPS[@]}"; do
        holds_vip "$v" && n=$((n + 1))
    done
    echo "$n"
}

missing_vips() {   # 本机未持有的 VIP，一行一个
    local v
    for v in "${VIPS[@]}"; do
        holds_vip "$v" || echo "${v%%/*}"
    done
}

all_vips_held() { [ "$(held_vip_count)" -eq "${#VIPS[@]}" ]; }

peer_ip() {
    case "$LOCAL_IP" in
        "$NODE1") echo "$NODE2" ;;
        "$NODE2") echo "$NODE1" ;;
        *) echo "" ;;
    esac
}

# 角色只看数据面 VIP：MySQL/Redis/etcdvip 都以它为入口。
is_on_vip() { holds_vip "$MYSQL_VIP"; }
