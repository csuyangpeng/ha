#!/bin/bash
# 节点成为 BACKUP：确认本机 etcd 健康，停止绑定 VIP 的 etcdvip
source "/home/sder/ha/replica/scripts/base.sh"

echo "================================================" 2>&1 | _ts_pipe >> "$LOG"
echo "[ETCD-SLAVE] 成为备份节点" 2>&1 | _ts_pipe >> "$LOG"
echo "本机IP: $LOCAL_IP" 2>&1 | _ts_pipe >> "$LOG"
echo "================================================" 2>&1 | _ts_pipe >> "$LOG"

# 与 redis_notify_slave 同理：启动期 BACKUP/MASTER 过渡重叠，已持有 VIP 时不得停 etcdvip
if is_on_vip; then
    echo "[ETCD-SLAVE] 本机已持有 VIP（已晋升 MASTER），跳过降级" 2>&1 | _ts_pipe >> "$LOG"
    exit 0
fi

wait_etcd_health() {
    local endpoint=$1 tries=${2:-30} i
    for i in $(seq 1 "$tries"); do
        if docker exec etcd etcdctl endpoint health --endpoints="$endpoint" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# 1. etcd 未运行则启动
if ! docker ps --format '{{.Names}}' | grep -qx etcd; then
    echo "etcd 容器未运行，启动..." 2>&1 | _ts_pipe >> "$LOG"
    ( cd "$REPLICA_DIR" && docker compose up -d etcd ) 2>&1 | _ts_pipe >> "$LOG"
fi

# 2. 健康检查，不健康才重启
if wait_etcd_health "http://${LOCAL_IP}:2379" 10; then
    echo "etcd 健康" 2>&1 | _ts_pipe >> "$LOG"
else
    echo "etcd 不健康，重启..." 2>&1 | _ts_pipe >> "$LOG"
    ( cd "$REPLICA_DIR" && docker compose restart etcd ) 2>&1 | _ts_pipe >> "$LOG"
    if ! wait_etcd_health "http://${LOCAL_IP}:2379" 30; then
        echo "[ERROR] etcd 重启后仍不健康" 2>&1 | _ts_pipe >> "$LOG"
        exit 1
    fi
fi

# 3. 停止 etcdvip（用 stop 而非 down，保留本机容器内数据，便于 VIP 回来后复用）
if docker ps -a --format '{{.Names}}' | grep -qx etcdvip; then
    echo "停止 etcdvip 服务..." 2>&1 | _ts_pipe >> "$LOG"
    ( cd "$REPLICA_DIR" && docker compose stop etcdvip ) 2>&1 | _ts_pipe >> "$LOG"
fi

# 4. 输出状态
echo "本机 etcd 状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status --endpoints="http://${LOCAL_IP}:2379" --write-out=table 2>&1 | _ts_pipe >> "$LOG"

STATUS=$(docker exec etcd etcdctl endpoint status --endpoints="http://${LOCAL_IP}:2379" --write-out=table 2>/dev/null)
IS_LEADER=$(echo "$STATUS" | awk -F'|' '/10\.18\./ {gsub(/ /,"",$6); print $6; exit}')
if [ "$IS_LEADER" = "true" ]; then
    echo "[WARN] 备份节点仍是 etcd leader（不影响主备切换，仅提示）" 2>&1 | _ts_pipe >> "$LOG"
fi

echo "[ETCD-SLAVE] 检查完成" 2>&1 | _ts_pipe >> "$LOG"
exit 0
