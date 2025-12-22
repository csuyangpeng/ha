#!/bin/bash
# 当节点成为 Keepalived BACKUP 时执行
source "/home/sder/ha/replica/scripts/base.sh"

LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "================================================" 2>&1 | _ts_pipe >> "$LOG"
echo "[ETCD-SLAVE] 成为备份节点" 2>&1 | _ts_pipe >> "$LOG"
echo "本机IP: $LOCAL_IP" 2>&1 | _ts_pipe >> "$LOG"
echo "================================================" 2>&1 | _ts_pipe >> "$LOG"

# 1. 检查 etcd 健康状态
echo "检查etcd健康状态..." 2>&1 | _ts_pipe >> "$LOG"
if docker exec etcd etcdctl endpoint health --endpoints=http://${LOCAL_IP}:2379 >/dev/null 2>&1; then
    echo "✅ etcd健康" 2>&1 | _ts_pipe >> "$LOG"
else
    echo "❌ etcd不健康，尝试重启..." 2>&1 | _ts_pipe >> "$LOG"
    cd /home/sder/ha/replica && docker-compose restart etcd 2>&1 | _ts_pipe >> "$LOG"
    sleep 3
fi

# stop etcdvip service
echo "停止etcdvip服务..." 2>&1 | _ts_pipe >> "$LOG"
cd /home/sder/ha/replica && docker-compose down etcdvip 2>&1 | _ts_pipe >> "$LOG"

# restart etcd service to ensure proper state
echo "重启etcd服务以确保正确状态..." 2>&1 | _ts_pipe >> "$LOG"
cd /home/sder/ha/replica && docker-compose restart etcd 2>&1 | _ts_pipe >> "$LOG"
sleep 3

# 2. 显示本机状态
echo "本机etcd状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>&1 | _ts_pipe >> "$LOG" 2>&1 || echo "无法获取状态" 2>&1 | _ts_pipe >> "$LOG"

# 3. 显示集群状态
echo "集群状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 --write-out=table 2>&1 | _ts_pipe >> "$LOG" 2>&1 || echo "无法获取集群状态" 2>&1 | _ts_pipe >> "$LOG"

# 4. 检查是否意外成为leader
TABLE_OUTPUT=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null || echo "")
LINE=$(echo "$TABLE_OUTPUT" | grep "http://")
if [[ -n "$LINE" ]]; then
    IS_LEADER=$(echo "$LINE" | awk -F"|" '{print $6}' | tr -d '[:space:]')
    if [[ "$IS_LEADER" == "true" ]]; then
        echo "⚠️  注意：备份节点但仍然是leader" 2>&1 | _ts_pipe >> "$LOG"
    fi
fi

echo "[ETCD-SLAVE] 检查完成" 2>&1 | _ts_pipe >> "$LOG"
exit 0