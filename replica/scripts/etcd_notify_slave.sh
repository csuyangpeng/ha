#!/bin/bash
# 当节点成为 Keepalived BACKUP 时执行

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "================================================" >> $LOG 2>&1
echo "$(date): [ETCD-SLAVE] 成为备份节点" >> $LOG 2>&1
echo "本机IP: $LOCAL_IP" >> $LOG 2>&1
echo "================================================" >> $LOG 2>&1

# 1. 检查 etcd 健康状态
echo "$(date): 检查etcd健康状态..." >> $LOG 2>&1
if docker exec etcd etcdctl endpoint health --endpoints=http://${LOCAL_IP}:2379 >/dev/null 2>&1; then
    echo "$(date): ✅ etcd健康" >> $LOG 2>&1
else
    echo "$(date): ❌ etcd不健康，尝试重启..." >> $LOG 2>&1
    cd /home/sder/ha/replica && docker-compose restart etcd >> $LOG 2>&1
    sleep 3
fi

# 2. 显示本机状态
echo "$(date): 本机etcd状态:" >> $LOG 2>&1
docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table >> $LOG 2>&1 2>&1 || echo "$(date): 无法获取状态" >> $LOG 2>&1

# 3. 显示集群状态
echo "$(date): 集群状态:" >> $LOG 2>&1
docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 --write-out=table >> $LOG 2>&1 2>&1 || echo "$(date): 无法获取集群状态" >> $LOG 2>&1

# 4. 检查是否意外成为leader
TABLE_OUTPUT=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null || echo "")
LINE=$(echo "$TABLE_OUTPUT" | grep "http://")
if [[ -n "$LINE" ]]; then
    IS_LEADER=$(echo "$LINE" | awk -F"|" '{print $6}' | tr -d '[:space:]')
    if [[ "$IS_LEADER" == "true" ]]; then
        echo "$(date): ⚠️  注意：备份节点但仍然是leader" >> $LOG 2>&1
    fi
fi

echo "$(date): [ETCD-SLAVE] 检查完成" >> $LOG 2>&1
exit 0