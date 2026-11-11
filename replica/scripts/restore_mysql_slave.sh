#!/bin/bash
# 从当前主库（VIP）全量重建本机 MySQL 从库
# 仅应在 BACKUP 节点执行；克隆/导出成功后才允许清空本地数据目录。
#
# 重建方式由 base.sh 的 RESTORE_MODE 决定：
#   clone（默认）：MySQL clone 插件物理克隆，秒级完成，不产生新的 datadir/
#                 server_uuid/初始化事务；失败自动回退 dump。
#   dump：         mysqldump 逻辑导出，跨版本/跨环境可用。
set -euo pipefail

source "/home/sder/ha/replica/scripts/base.sh"

MASTER_IP="$MYSQL_VIP"
# 每次运行用独立临时文件：/tmp 带 sticky 位（fs.protected_regular），
# 上一次以 root 运行残留的固定文件名会让本次以 sder 运行 scp 时报 Permission denied。
BACKUP_FILE="/tmp/master_dump.$$.sql"          # 对端（主库）上的 dump
LOCAL_FILE="/tmp/master_dump_local.$$.sql"     # 本机上的副本
CLONE_DIR="/tmp/replica_clone.$$"              # 对端（主库）容器内的本地克隆目录

# VIP 会在两台节点间漂移，SSH 主机密钥也随之变化；这里不校验 known_hosts，
# 否则每次切换后自动重建都会因 "Host key verification failed" 失败。
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=5)

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 预检：确认当前用户能清理 data/mysql。健康检查/keepalived 以 root 运行；
# 以 sder 手工执行时必须先 chown（deploy_cluster.sh 的 fallback_restore 会做），
# 否则会在 docker stop 之后才因权限失败，留下半清空的 datadir。
preflight() {
    local bad
    [ -d "${REPLICA_DIR}/data/mysql" ] || return 0
    # 只看目录：rm -rf 能否删除取决于目录是否可写，与文件自身权限无关。
    # 不能看文件：mysql.sock 是指向容器内 /var/run/mysqld 的悬空软链接，
    # `[ -w ]` 对悬空链接恒为假，会把 root 也误判成无权限。
    bad=$(find "${REPLICA_DIR}/data/mysql" -maxdepth 4 -type d ! -writable -print -quit 2>/dev/null) || true
    [ -z "$bad" ] && return 0
    log "[RESTORE] 无权限清理 ${bad}，请以 root 运行，或先 sudo chown -R $(id -un) ${bad}"
    return 1
}
preflight || exit 1

# 手动与自动重建共用一把全局锁：健康检查在拉起前也会探测同一把锁。
# 拿不到锁说明已有重建在进行，直接退出，避免两个进程同时清空 data/mysql
# 并并发导入（会撞出 GTID_PURGED 3546 / super-read-only 1290）。
# 用 -w 2 而不是 -n：健康检查的探测会瞬时持锁，短暂等待可避免误判为"已有重建"。
[ -e "$RESTORE_LOCK_FILE" ] || : > "$RESTORE_LOCK_FILE" 2>/dev/null || true
chmod 666 "$RESTORE_LOCK_FILE" 2>/dev/null || true
exec 8>"$RESTORE_LOCK_FILE" || { log "[RESTORE] 无法打开重建锁 ${RESTORE_LOCK_FILE}"; exit 1; }
if ! flock -w 2 8; then
    log "[RESTORE] 已有重建正在进行，本次退出"
    exit 0
fi

# 拿到锁之后再写标记：避免并发时互相覆盖/删除 .restoring
# （重建期间通知健康检查不要强制只读：导入需要用 root 写库）
RESTORE_FLAG="${REPLICA_DIR}/.restoring"
echo $$ > "$RESTORE_FLAG"

# 无论成功、失败还是被中断，都清掉本机副本、标记和对端 dump，避免 /tmp 残留
cleanup() {
    rm -f "$RESTORE_FLAG" "$LOCAL_FILE"
    ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" "rm -f ${BACKUP_FILE}" >/dev/null 2>&1 || true
    ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" "docker exec mysql rm -rf ${CLONE_DIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if is_on_vip; then
    log "[RESTORE] 本机持有 VIP，拒绝重建（应在 BACKUP 节点执行）"
    exit 1
fi

case "$RESTORE_MODE" in
    clone|dump) ;;
    *) log "[RESTORE] 未知 RESTORE_MODE=${RESTORE_MODE}，按 dump 处理"; RESTORE_MODE=dump ;;
esac

log "=== 开始重建本机 MySQL 从库（方式: ${RESTORE_MODE}，源: ${MASTER_IP}）==="

# ---------------- 公共 ----------------

wait_mysql_ready() {   # wait_mysql_ready <最长等待秒数>
    local timeout=$1 waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if docker exec -e MYSQL_PWD="$MYSQL_PASS" mysql mysql -h 127.0.0.1 -u"$MYSQL_USER" \
            -N -B -e 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

configure_replication() {
    mysql_exec <<EOF >> "$LOG" 2>&1
SET GLOBAL read_only=ON;
SET GLOBAL super_read_only=ON;
CHANGE MASTER TO
  MASTER_HOST='${MASTER_IP}',
  MASTER_USER='${MYSQL_USER}',
  MASTER_PASSWORD='${MYSQL_PASS}',
  MASTER_PORT=${MYSQL_PORT},
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
START SLAVE;
EOF
}

verify_replication() {
    local status io sql_r
    for _ in $(seq 1 30); do
        status=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null)
        io=$(echo "$status" | awk -F': ' '/Slave_IO_Running:/{print $2}')
        sql_r=$(echo "$status" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
        [ "$io" = "Yes" ] && [ "$sql_r" = "Yes" ] && break
        sleep 2
    done
    { echo "---- SHOW SLAVE STATUS ----"; echo "$status"; } >> "$LOG"
    if [ "$io" = "Yes" ] && [ "$sql_r" = "Yes" ]; then
        log "=== 重建完成：复制正常 ==="
        return 0
    fi
    log "[RESTORE] 重建后复制仍未建立（IO=${io:-N/A}, SQL=${sql_r:-N/A}）"
    return 1
}

# ---------------- 方式一：物理克隆 ----------------

# 在主库（VIP）上执行 mysql 客户端；查询走 stdin，避免 SQL 里的引号被 ssh 二次解析
remote_query() {   # $1=SQL -> 无表头结果
    printf '%s\n' "$1" | ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" \
        "docker exec -i -e MYSQL_PWD='${MYSQL_PASS}' mysql mysql -u'${MYSQL_USER}' -N -B"
}

remote_sql() {     # 标准输入为 SQL 脚本
    ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" \
        "docker exec -i -e MYSQL_PWD='${MYSQL_PASS}' mysql mysql -u'${MYSQL_USER}'"
}

# 主库侧：加载 clone 插件 + 准备带 BACKUP_ADMIN 的克隆账号（幂等）
clone_donor_prepare() {
    local n
    n=$(remote_query "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_NAME='clone'" 2>/dev/null) \
        || { log "[CLONE] 无法访问主库 ${MASTER_IP} 的 MySQL"; return 1; }
    if [ "${n:-0}" = "0" ]; then
        if ! remote_query "INSTALL PLUGIN clone SONAME 'mysql_clone.so'" >> "$LOG" 2>&1; then
            log "[CLONE] 主库加载 clone 插件失败"
            return 1
        fi
    fi
    if ! printf '%s\n' \
        "CREATE USER IF NOT EXISTS '${CLONE_USER}'@'%' IDENTIFIED BY '${CLONE_PASS}';" \
        "ALTER USER '${CLONE_USER}'@'%' IDENTIFIED BY '${CLONE_PASS}';" \
        "GRANT BACKUP_ADMIN ON *.* TO '${CLONE_USER}'@'%';" \
        | remote_sql >> "$LOG" 2>&1; then
        log "[CLONE] 主库准备克隆账号失败"
        return 1
    fi
}

restore_by_clone() {
    local t0 t1 state g0 tables

    # 远程 CLONE INSTANCE 要求备库在克隆后“自行重启”，容器里 mysqld 是 PID 1、
    # 没有 systemd/mysqld_safe 监管，会报 3707 (Restart server failed)。
    # 因此改用：donor 本地克隆（不重启、不阻塞 DML）→ tar 流式传到本机 → 本机启容器。

    # 1) donor 侧准备插件/账号（主库可写，运行时 INSTALL 可用）
    clone_donor_prepare || return 1
    g0=$(remote_query "SELECT REPLACE(@@gtid_executed, '\n', '')" 2>/dev/null) || true

    # 2) donor 本地克隆
    log "[CLONE] 在 ${MASTER_IP} 创建本地克隆 ${CLONE_DIR}"
    t0=$(date +%s)
    if ! remote_query "CLONE LOCAL DATA DIRECTORY='${CLONE_DIR}'" >> "$LOG" 2>&1; then
        log "[CLONE] donor 本地克隆失败"
        return 1
    fi
    state=$(remote_query "SELECT state FROM performance_schema.clone_status" 2>/dev/null)
    if [ "$state" != "Completed" ]; then
        log "[CLONE] donor 克隆状态异常（${state:-空}）"
        return 1
    fi
    log "[CLONE] donor 本地克隆完成，开始传到本机"

    # 3) 停本机 MySQL、清空 datadir、流式解包（#clone 是克隆插件的状态目录，不属于 datadir）
    docker stop mysql >> "$LOG" 2>&1 || true
    rm -rf "${REPLICA_DIR:?}/data/mysql/"*
    if ! ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" \
            "docker exec mysql tar -C ${CLONE_DIR} --exclude='./#clone' -cf - ." 2>> "$LOG" \
            | tar -C "${REPLICA_DIR}/data/mysql" -xf - >> "$LOG" 2>&1; then
        log "[CLONE] 克隆数据传输出错"
        return 1
    fi

    # 4) 启动并校验：业务库存在，且 GTID 集合包含 donor 克隆前状态
    # 克隆目录不含 performance_schema/；若 compose 预加载了 clone 插件，
    # 插件初始化要在该目录下建自己的 PFS 表，目录缺失会导致插件加载失败。
    mkdir -p "${REPLICA_DIR}/data/mysql/performance_schema"
    chown --reference="${REPLICA_DIR}/data/mysql/mysql" "${REPLICA_DIR}/data/mysql/performance_schema" 2>/dev/null || true
    chmod --reference="${REPLICA_DIR}/data/mysql/mysql" "${REPLICA_DIR}/data/mysql/performance_schema" 2>/dev/null || true

    log "[CLONE] 启动 MySQL"
    if ! docker start mysql >> "$LOG" 2>&1; then
        ( cd "$REPLICA_DIR" && docker compose up -d mysql ) >> "$LOG" 2>&1
    fi
    if ! wait_mysql_ready 300; then
        log "[CLONE] 克隆后 MySQL 300s 内未就绪"
        return 1
    fi

    tables=$(mysql_query "SELECT COUNT(*) FROM information_schema.tables
                          WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema')")
    if [ -z "$tables" ] || [ "${tables:-0}" -lt 1 ] 2>/dev/null; then
        log "[CLONE] 校验失败：未看到业务库（table 数=${tables:-空}）"
        return 1
    fi
    if [ -n "$g0" ] && [ "$(mysql_query "SELECT GTID_SUBSET('${g0}', @@gtid_executed)")" != "1" ]; then
        log "[CLONE] 校验失败：GTID 集合未包含 donor 克隆前状态"
        return 1
    fi
    t1=$(date +%s)
    log "[CLONE] 克隆成功，用时 $((t1 - t0))s（业务表 ${tables} 张）"

    configure_replication
    verify_replication
}

# ---------------- 方式二：mysqldump 逻辑重建 ----------------

restore_by_dump() {
    log "1. 在主库 ${MASTER_IP} 导出全量备份"
    ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" "docker exec mysql mysqldump -uroot -p'${MYSQL_PASS}' \
      --all-databases --single-transaction --master-data=2 --set-gtid-purged=ON \
      --routines --events > ${BACKUP_FILE}" >> "$LOG" 2>&1

    log "2. 复制备份文件到本机"
    scp -q "${SSH_OPTS[@]}" "sder@${MASTER_IP}:${BACKUP_FILE}" "$LOCAL_FILE" >> "$LOG" 2>&1
    if [ ! -s "$LOCAL_FILE" ]; then
        log "[RESTORE] 备份文件为空，终止（未修改本地数据）"
        exit 1
    fi
    # mysqldump 正常结束时会在末尾写 "-- Dump completed"；缺失说明传输/导出被截断，
    # 此时绝不能清空本地数据目录。
    if ! tail -n 3 "$LOCAL_FILE" | grep -q -- "Dump completed"; then
        log "[RESTORE] 备份文件不完整（缺少 Dump completed 结束标记），终止（未修改本地数据）"
        exit 1
    fi
    log "   备份大小: $(du -h "$LOCAL_FILE" | awk '{print $1}')"

    log "3. 停止本地 MySQL 并清空数据目录"
    docker stop mysql >> "$LOG" 2>&1 || true
    docker rm -f mysql >> "$LOG" 2>&1 || true
    rm -rf "${REPLICA_DIR:?}/data/mysql/"*

    log "4. 重新创建 MySQL 容器"
    ( cd "$REPLICA_DIR" && docker compose up -d mysql ) >> "$LOG" 2>&1

    log "5. 等待 MySQL 就绪"
    if ! wait_mysql_ready 300; then
        log "[RESTORE] MySQL 启动超时"
        exit 1
    fi

    log "6. 导入数据"
    docker exec -i mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" < "$LOCAL_FILE" >> "$LOG" 2>&1

    log "7. 配置复制"
    configure_replication

    log "8. 校验复制状态"
    verify_replication
}

# ---------------- 入口 ----------------

if [ "$RESTORE_MODE" = "clone" ]; then
    if restore_by_clone; then
        exit 0
    fi
    log "[RESTORE] 物理克隆失败，回退 mysqldump 全量重建"
fi

restore_by_dump
