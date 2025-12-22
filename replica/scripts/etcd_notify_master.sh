#!/bin/bash
# 当节点成为 Keepalived MASTER 时执行（Etcd 不需要特殊操作）
source "/home/sder/ha/replica/scripts/base.sh"

LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "================================================" 2>&1 | _ts_pipe >> "$LOG"
echo "[ETCD-MASTER] VIP切换，迁移leader到本机" 2>&1 | _ts_pipe >> "$LOG"
echo "本机IP: $LOCAL_IP" 2>&1 | _ts_pipe >> "$LOG"
echo "================================================" 2>&1 | _ts_pipe >> "$LOG"

# 1. 检查 etcd 是否运行
if ! docker ps | grep -q etcd; then
    echo "❌ etcd容器未运行，尝试启动..." 2>&1 | _ts_pipe >> "$LOG"
    cd /home/sder/ha/replica && docker-compose up -d etcd 2>&1 | _ts_pipe >> "$LOG"
    sleep 3
fi

# 2. 获取本机状态
echo "获取本机etcd状态..." 2>&1 | _ts_pipe >> "$LOG"
TABLE_OUTPUT=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null || echo "")

if [[ -z "$TABLE_OUTPUT" ]]; then
    echo "❌ 无法获取etcd状态" 2>&1 | _ts_pipe >> "$LOG"
    exit 1
fi

# start etcdvip service
echo "启动etcdvip服务..." 2>&1 | _ts_pipe >> "$LOG"
cd /home/sder/ha/replica && docker-compose up -d etcdvip 2>&1 | _ts_pipe >> "$LOG"

# # 3. 解析表格：第2列=ID，第5列=IS_LEADER
# LINE=$(echo "$TABLE_OUTPUT" | grep "http://")
# if [[ -z "$LINE" ]]; then
#     echo "❌ 无法解析表格输出" 2>&1 | _ts_pipe >> "$LOG"
#     exit 1
# fi

# MY_ID=$(echo "$LINE" | awk -F"|" '{print $3}' | tr -d '[:space:]')
# IS_LEADER=$(echo "$LINE" | awk -F"|" '{print $6}' | tr -d '[:space:]')

# echo "解析结果 - ID: $MY_ID, IS_LEADER: $IS_LEADER" 2>&1 | _ts_pipe >> "$LOG"

# # 4. 如果已经是leader，直接返回
# if [[ "$IS_LEADER" == "true" ]]; then
#     echo "✅ 本机已经是etcd leader" 2>&1 | _ts_pipe >> "$LOG"
#     echo "显示集群状态:" 2>&1 | _ts_pipe >> "$LOG"
#     docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 --write-out=table 2>&1 | _ts_pipe >> "$LOG" 2>/dev/null
#     exit 0
# fi

# echo "⚠️  本机不是leader，需要迁移" 2>&1 | _ts_pipe >> "$LOG"

# # 5. 找到当前leader
# # LEADER_IP=""
# # for IP in 10.18.1.27 10.18.1.28; do
# #     if [[ "$IP" == "$LOCAL_IP" ]]; then
# #         continue
# #     fi
    
# #     if docker exec etcd etcdctl endpoint status --endpoints=http://${IP}:2379 --write-out=table 2>/dev/null | grep -q "true.*IS LEADER"; then
# #         LEADER_IP="$IP"
# #         echo "找到当前leader: $LEADER_IP" 2>&1 | _ts_pipe >> "$LOG"
# #         break
# #     fi
# # done

# # 6. 执行迁移
# # if [[ -n "$LEADER_IP" ]]; then
# #     echo "执行迁移: move-leader $MY_ID --endpoints=http://${LEADER_IP}:2379" 2>&1 | _ts_pipe >> "$LOG"
# #     docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://${LEADER_IP}:2379 2>&1 | _ts_pipe >> "$LOG"
# #     MIGRATE_RESULT=$?
# #     echo "迁移命令返回值: $MIGRATE_RESULT" 2>&1 | _ts_pipe >> "$LOG"
# # else
#     # echo "⚠️  无法找到leader，尝试从任一节点迁移" 2>&1 | _ts_pipe >> "$LOG"
# echo "MY_ID: " $MY_ID 2>&1 | _ts_pipe >> "$LOG" 
# docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://10.18.1.27:2379 2>&1 | _ts_pipe >> "$LOG" || true
# docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://10.18.1.28:2379 2>&1 | _ts_pipe >> "$LOG" || true
# # fi

# # 7. 验证结果
# echo "验证迁移结果..." 2>&1 | _ts_pipe >> "$LOG"
# sleep 2

# FINAL_CHECK=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null | grep "http://" | awk -F"|" '{print $6}' | tr -d '[:space:]' || echo "unknown")

# # 去掉前后的空格 FINAL_CHECK


# if [[ "$FINAL_CHECK" == "true" ]]; then
#     echo "✅ leader迁移成功" 2>&1 | _ts_pipe >> "$LOG"
# else
#     echo "⚠️  leader迁移可能失败" 2>&1 | _ts_pipe >> "$LOG"
# fi

# 8. 显示最终集群状态
echo "最终集群状态:" 2>&1 | _ts_pipe >> "$LOG"
docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 --write-out=table 2>&1 | _ts_pipe >> "$LOG" 2>/dev/null || true

echo "[ETCD-MASTER] 切换完成" 2>&1 | _ts_pipe >> "$LOG"
exit 0
