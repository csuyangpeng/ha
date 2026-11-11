#!/bin/bash
# 节点成为 MASTER：确保本机 etcd 健康，并启动绑定 VIP 的 etcdvip
source "/home/sder/ha/replica/scripts/base.sh"

echo "================================================" 2>&1 | _ts_pipe >> "$LOG"
echo "[ETCD-MASTER] VIP 切换，启动 etcdvip" 2>&1 | _ts_pipe >> "$LOG"
echo "本机IP: $LOCAL_IP" 2>&1 | _ts_pipe >> "$LOG"
echo "================================================" 2>&1 | _ts_pipe >> "$LOG"

ETCD_ENDPOINT="http://${LOCAL_IP}:2379"
ETCDVIP_PEER="http://${MYSQL_VIP}:23800"
ETCDVIP_CLIENT="http://127.0.0.1:23790"

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

# etcdvip 的数据只保存在容器可写层，VIP 在哪台就只有哪台的副本是新的。
# 从备节点切回来时旧副本的 raft 日志会落后于集群，etcd 会直接 panic
# （tocommit is out of range）。因此提升为主时若本机副本不可用，就把它
# 作为新成员重新加入集群，而不是复用过期数据。
etcdvip_member_id() {
    docker exec etcd etcdctl --command-timeout=5s --endpoints="$ETCD_ENDPOINT" \
        member list 2>/dev/null | awk -F',' '/, etcdvip,/{gsub(/ /,"",$1); print $1; exit}'
}

etcdvip_healthy() {
    docker ps --format '{{.Names}}' | grep -qx etcdvip || return 1
    docker exec etcd etcdctl --command-timeout=5s \
        endpoint health --endpoints="$ETCDVIP_CLIENT" >/dev/null 2>&1 || return 1
    [ -n "$(etcdvip_member_id)" ]
}

reset_etcdvip_member() {
    local mid
    echo "移除本机 etcdvip 容器（清空过期数据）" 2>&1 | _ts_pipe >> "$LOG"
    ( cd "$REPLICA_DIR" && docker compose stop etcdvip ) >> "$LOG" 2>&1 || true
    docker rm -f etcdvip >> "$LOG" 2>&1 || true

    mid=$(etcdvip_member_id)
    if [ -n "$mid" ]; then
        echo "从 etcd 集群移除旧成员 etcdvip(${mid})" 2>&1 | _ts_pipe >> "$LOG"
        if ! docker exec etcd etcdctl --command-timeout=10s --endpoints="$ETCD_ENDPOINT" \
            member remove "$mid" >> "$LOG" 2>&1; then
            echo "[ERROR] 移除 etcdvip 成员失败" 2>&1 | _ts_pipe >> "$LOG"
            return 1
        fi
    fi

    echo "以新成员加入 etcd 集群（peer=${ETCDVIP_PEER}）" 2>&1 | _ts_pipe >> "$LOG"
    if ! docker exec etcd etcdctl --command-timeout=10s --endpoints="$ETCD_ENDPOINT" \
        member add etcdvip --peer-urls="$ETCDVIP_PEER" >> "$LOG" 2>&1; then
        echo "[ERROR] 添加 etcdvip 成员失败" 2>&1 | _ts_pipe >> "$LOG"
        return 1
    fi

    ( cd "$REPLICA_DIR" && docker compose up -d etcdvip ) >> "$LOG" 2>&1
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

# 2. 启动绑定 VIP 的 etcdvip（本机之前的副本可能已过期，必要时重建成员）
if etcdvip_healthy; then
    echo "etcdvip 已健康，跳过重建" 2>&1 | _ts_pipe >> "$LOG"
else
    echo "etcdvip 未运行或数据过期，以新成员重建..." 2>&1 | _ts_pipe >> "$LOG"
    if ! reset_etcdvip_member; then
        echo "[ERROR] etcdvip 成员重建失败" 2>&1 | _ts_pipe >> "$LOG"
        exit 1
    fi
    if wait_etcd_health "$ETCDVIP_CLIENT" 30; then
        echo "etcdvip 健康（VIP:23790）" 2>&1 | _ts_pipe >> "$LOG"
    else
        echo "[ERROR] etcdvip 未就绪（127.0.0.1:23790），检查容器日志" 2>&1 | _ts_pipe >> "$LOG"
        docker logs --tail 30 etcdvip 2>&1 | _ts_pipe >> "$LOG"
        exit 1
    fi
fi

# 3. 输出集群状态
echo "集群状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status \
    --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 \
    --write-out=table 2>&1 | _ts_pipe >> "$LOG"

echo "[ETCD-MASTER] 切换完成" 2>&1 | _ts_pipe >> "$LOG"
exit 0
