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
MYSQL_VIP="10.18.1.30"
NODE1="10.18.1.27"
NODE2="10.18.1.28"

LOCAL_IP=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -E '^10\.18\.1\.(27|28)$' | head -1)
[ -n "$LOCAL_IP" ] || LOCAL_IP=$(hostname -I | awk '{print $1}')

# ---- 凭据 ----
MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"
MYSQL_PORT=3306

REDIS_PASS="A8K5h7+6!?"
REDIS_PORT=6379

# ---- 运行时文件 ----
LOCK_FILE="/var/run/replica_health_check.lock"
RESTORE_TS_FILE="/var/run/replica_restore_last"
RESTORE_INTERVAL=600    # 从库重建最小间隔（秒）
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

is_on_vip() {
    ip addr show dev "$IFACE" 2>/dev/null | grep -q "inet $MYSQL_VIP/"
}
