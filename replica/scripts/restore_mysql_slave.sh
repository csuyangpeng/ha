#!/bin/bash
# 从当前主库（VIP）全量重建本机 MySQL 从库
# 仅应在 BACKUP 节点执行；导出成功后才允许清空本地数据目录。
set -euo pipefail

source "/home/sder/ha/replica/scripts/base.sh"

# 重建期间通知健康检查不要强制只读：导入需要用 root 写库。
# （备库正常状态下是 super_read_only=ON，root 也写不进去）
RESTORE_FLAG="${REPLICA_DIR}/.restoring"
echo $$ > "$RESTORE_FLAG"
trap 'rm -f "$RESTORE_FLAG"' EXIT

MASTER_IP="$MYSQL_VIP"
BACKUP_FILE="/tmp/master_dump.sql"
LOCAL_FILE="/tmp/master_dump_local.sql"

# VIP 会在两台节点间漂移，SSH 主机密钥也随之变化；这里不校验 known_hosts，
# 否则每次切换后自动重建都会因 "Host key verification failed" 失败。
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o BatchMode=yes -o ConnectTimeout=5)

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

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

rm -f "$BACKUP_FILE" 2>/dev/null || true
ssh "${SSH_OPTS[@]}" "sder@${MASTER_IP}" "rm -f ${BACKUP_FILE}" >> "$LOG" 2>&1 || true

if [ "$IO_RUNNING" = "Yes" ] && [ "$SQL_RUNNING" = "Yes" ]; then
    log "=== 重建完成：复制正常 ==="
    exit 0
fi

log "[RESTORE] 重建后复制仍未建立（IO=${IO_RUNNING:-N/A}, SQL=${SQL_RUNNING:-N/A}）"
exit 1
