#!/bin/bash
# 节点成为 MASTER：确保本机 etcd 健康，并启动绑定 VIP 的 etcdvip
source "/home/sder/ha/replica/scripts/base.sh"

echo "================================================" 2>&1 | _ts_pipe >> "$LOG"
echo "[ETCD-MASTER] VIP 切换，启动 etcdvip" 2>&1 | _ts_pipe >> "$LOG"
echo "本机IP: $LOCAL_IP" 2>&1 | _ts_pipe >> "$LOG"
echo "================================================" 2>&1 | _ts_pipe >> "$LOG"

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

# 1. 确保 etcd 容器在运行
if ! docker ps --format '{{.Names}}' | grep -qx etcd; then
    echo "etcd 容器未运行，启动..." 2>&1 | _ts_pipe >> "$LOG"
    ( cd "$REPLICA_DIR" && docker compose up -d etcd ) 2>&1 | _ts_pipe >> "$LOG"
fi

if ! wait_etcd_health "http://${LOCAL_IP}:2379" 30; then
    echo "[ERROR] etcd 健康检查超时（http://${LOCAL_IP}:2379）" 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi
echo "etcd 健康" 2>&1 | _ts_pipe >> "$LOG"

# 2. 启动绑定 VIP 的 etcdvip
echo "启动 etcdvip 服务..." 2>&1 | _ts_pipe >> "$LOG"
( cd "$REPLICA_DIR" && docker compose up -d etcdvip ) 2>&1 | _ts_pipe >> "$LOG"

if wait_etcd_health "http://127.0.0.1:23790" 15; then
    echo "etcdvip 健康（VIP:23790）" 2>&1 | _ts_pipe >> "$LOG"
else
    echo "[ERROR] etcdvip 未就绪（127.0.0.1:23790），检查容器日志" 2>&1 | _ts_pipe >> "$LOG"
    docker logs --tail 20 etcdvip 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi

# 3. 输出集群状态
echo "集群状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status \
    --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 \
    --write-out=table 2>&1 | _ts_pipe >> "$LOG"

echo "[ETCD-MASTER] 切换完成" 2>&1 | _ts_pipe >> "$LOG"
exit 0
