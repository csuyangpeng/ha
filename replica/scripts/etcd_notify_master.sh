#!/bin/bash
# 当节点成为 Keepalived MASTER 时执行（Etcd 不需要特殊操作）

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"
LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "================================================" >> $LOG 2>&1
echo "$(date): [ETCD-MASTER] VIP切换，迁移leader到本机" >> $LOG 2>&1
echo "本机IP: $LOCAL_IP" >> $LOG 2>&1
echo "================================================" >> $LOG 2>&1

# 1. 检查 etcd 是否运行
if ! docker ps | grep -q etcd; then
    echo "$(date): ❌ etcd容器未运行，尝试启动..." >> $LOG 2>&1
    cd /home/sder/ha/replica && docker-compose up -d etcd >> $LOG 2>&1
    sleep 3
fi

# 2. 获取本机状态
echo "$(date): 获取本机etcd状态..." >> $LOG 2>&1
TABLE_OUTPUT=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null || echo "")

if [[ -z "$TABLE_OUTPUT" ]]; then
    echo "$(date): ❌ 无法获取etcd状态" >> $LOG 2>&1
    exit 1
fi

# start etcdvip service
echo "$(date): 启动etcdvip服务..." >> $LOG 2>&1
cd /home/sder/ha/replica && docker-compose up -d etcdvip >> $LOG 2>&1

# # 3. 解析表格：第2列=ID，第5列=IS_LEADER
# LINE=$(echo "$TABLE_OUTPUT" | grep "http://")
# if [[ -z "$LINE" ]]; then
#     echo "$(date): ❌ 无法解析表格输出" >> $LOG 2>&1
#     exit 1
# fi

# MY_ID=$(echo "$LINE" | awk -F"|" '{print $3}' | tr -d '[:space:]')
# IS_LEADER=$(echo "$LINE" | awk -F"|" '{print $6}' | tr -d '[:space:]')

# echo "$(date): 解析结果 - ID: $MY_ID, IS_LEADER: $IS_LEADER" >> $LOG 2>&1

# # 4. 如果已经是leader，直接返回
# if [[ "$IS_LEADER" == "true" ]]; then
#     echo "$(date): ✅ 本机已经是etcd leader" >> $LOG 2>&1
#     echo "$(date): 显示集群状态:" >> $LOG 2>&1
#     docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 --write-out=table >> $LOG 2>&1 2>/dev/null
#     exit 0
# fi

# echo "$(date): ⚠️  本机不是leader，需要迁移" >> $LOG 2>&1

# # 5. 找到当前leader
# # LEADER_IP=""
# # for IP in 10.18.1.27 10.18.1.28; do
# #     if [[ "$IP" == "$LOCAL_IP" ]]; then
# #         continue
# #     fi
    
# #     if docker exec etcd etcdctl endpoint status --endpoints=http://${IP}:2379 --write-out=table 2>/dev/null | grep -q "true.*IS LEADER"; then
# #         LEADER_IP="$IP"
# #         echo "$(date): 找到当前leader: $LEADER_IP" >> $LOG 2>&1
# #         break
# #     fi
# # done

# # 6. 执行迁移
# # if [[ -n "$LEADER_IP" ]]; then
# #     echo "$(date): 执行迁移: move-leader $MY_ID --endpoints=http://${LEADER_IP}:2379" >> $LOG 2>&1
# #     docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://${LEADER_IP}:2379 >> $LOG 2>&1
# #     MIGRATE_RESULT=$?
# #     echo "$(date): 迁移命令返回值: $MIGRATE_RESULT" >> $LOG 2>&1
# # else
#     # echo "$(date): ⚠️  无法找到leader，尝试从任一节点迁移" >> $LOG 2>&1
# echo "MY_ID: " $MY_ID >> $LOG 2>&1 
# docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://10.18.1.27:2379 >> $LOG 2>&1 || true
# docker exec etcd etcdctl move-leader "$MY_ID" --endpoints=http://10.18.1.28:2379 >> $LOG 2>&1 || true
# # fi

# # 7. 验证结果
# echo "$(date): 验证迁移结果..." >> $LOG 2>&1
# sleep 2

# FINAL_CHECK=$(docker exec etcd etcdctl endpoint status --endpoints=http://${LOCAL_IP}:2379 --write-out=table 2>/dev/null | grep "http://" | awk -F"|" '{print $6}' | tr -d '[:space:]' || echo "unknown")

# # 去掉前后的空格 FINAL_CHECK


# if [[ "$FINAL_CHECK" == "true" ]]; then
#     echo "$(date): ✅ leader迁移成功" >> $LOG 2>&1
# else
#     echo "$(date): ⚠️  leader迁移可能失败" >> $LOG 2>&1
# fi

# 8. 显示最终集群状态
echo "$(date): 最终集群状态:" >> $LOG 2>&1
docker exec etcd etcdctl endpoint status --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 --write-out=table >> $LOG 2>&1 2>/dev/null || true

echo "$(date): [ETCD-MASTER] 切换完成" >> $LOG 2>&1
exit 0
