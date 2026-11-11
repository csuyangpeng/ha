#!/bin/bash
# 从当前主库（VIP）全量重建本机 MySQL 从库
# 仅应在 BACKUP 节点执行；导出成功后才允许清空本地数据目录。
set -euo pipefail

source "/home/sder/ha/replica/scripts/base.sh"

MASTER_IP="$MYSQL_VIP"
# 每次运行用独立临时文件：/tmp 带 sticky 位（fs.protected_regular），
# 上一次以 root 运行残留的固定文件名会让本次以 sder 运行 scp 时报 Permission denied。
BACKUP_FILE="/tmp/master_dump.$$.sql"          # 对端（主库）上的 dump
LOCAL_FILE="/tmp/master_dump_local.$$.sql"     # 本机上的副本

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
}
trap cleanup EXIT

if is_on_vip; then
    log "[RESTORE] 本机持有 VIP，拒绝重建（应在 BACKUP 节点执行）"
    exit 1
fi

log "=== 开始重建本机 MySQL 从库（源: ${MASTER_IP}）==="

# 1. 在主库上导出（通过 ssh 进入对端容器，避免依赖本机 mysql 客户端）
log "1. 在主库 ${MASTER_IP} 导出全量备份"
ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" "docker exec mysql mysqldump -uroot -p'${MYSQL_PASS}' \
  --all-databases --single-transaction --master-data=2 --set-gtid-purged=ON \
  --routines --events > ${BACKUP_FILE}" >> "$LOG" 2>&1

# 2. 拉回本地并校验
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

# 3. 停止并重建 MySQL 容器
log "3. 停止本地 MySQL 并清空数据目录"
docker stop mysql >> "$LOG" 2>&1 || true
docker rm mysql >> "$LOG" 2>&1 || true
rm -rf "${REPLICA_DIR:?}/data/mysql/"*

log "4. 重新创建 MySQL 容器"
( cd "$REPLICA_DIR" && docker compose up -d mysql ) >> "$LOG" 2>&1

log "5. 等待 MySQL 就绪"
# 首次初始化时临时实例 --skip-networking，必须用 TCP + 密码确认正式实例已就绪
READY=0
for _ in $(seq 1 100); do
    if docker exec -e MYSQL_PWD="$MYSQL_PASS" mysql mysql -h 127.0.0.1 -u"$MYSQL_USER" \
        -N -B -e 'SELECT 1' >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 3
done
if [ "$READY" -ne 1 ]; then
    log "[RESTORE] MySQL 启动超时"
    exit 1
fi

# 6. 导入数据
log "6. 导入数据"
docker exec -i mysql mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" < "$LOCAL_FILE" >> "$LOG" 2>&1

# 7. 配置复制（源为 VIP），并置只读
log "7. 配置复制"
mysql_exec <<EOF >> "$LOG" 2>&1
SET GLOBAL read_only=ON;
SET GLOBAL super_read_only=ON;
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='${MASTER_IP}',
  MASTER_USER='${MYSQL_USER}',
  MASTER_PASSWORD='${MYSQL_PASS}',
  MASTER_PORT=${MYSQL_PORT},
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
START SLAVE;
EOF

# 8. 校验
log "8. 校验复制状态"
for _ in $(seq 1 30); do
    STATUS=$(mysql_exec -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    IO_RUNNING=$(echo "$STATUS" | awk -F': ' '/Slave_IO_Running:/{print $2}')
    SQL_RUNNING=$(echo "$STATUS" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
    [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ] && break
    sleep 2
done
echo "$STATUS" >> "$LOG"

# 临时文件（本机副本、对端 dump、.restoring）由 cleanup() trap 统一清理

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    log "=== 重建完成：复制正常 ==="
    exit 0
fi

log "[RESTORE] 重建后复制仍未建立（IO=${IO_RUNNING:-N/A}, SQL=${SQL_RUNNING:-N/A}）"
exit 1
