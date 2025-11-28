#!/bin/bash

echo "=== 开始集群测试 ==="
bash cluster_check.sh
bash cluster_operator.sh
bash cluster_consistency.sh
echo "=== 集群测试完成 ==="

# one node fail


# all node ok
# === 开始集群测试 ===
# === 集群初始状态检查 ===
# 1. 节点网络连通性:
# ✅ 10.18.1.27 可达
# ✅ 10.18.1.28 可达
# ✅ 10.18.1.29 可达

# 2. Redis集群状态:
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# da7416ac01c0d2a7766bb874d2d3fdc21e616a38 10.18.1.29:6380@16380 master - 0 1760600186000 7 connected 5461-10922
# ed918a2d51e9aff8ff8dea9cebceda2a06039bf8 10.18.1.28:6380@16380 master - 0 1760600186000 8 connected 0-5460
# 8d8784212d71f9fa6c90eafbb3140fc398673346 10.18.1.29:6379@16379 master - 0 1760600186754 5 connected 10923-16383
# 6c8bb97a32f9a56741f606f5d0c74ce6116672e9 10.18.1.27:6380@16380 slave 8d8784212d71f9fa6c90eafbb3140fc398673346 0 1760600185000 5 connected
# c853460be39f087c86d75a5a7f455587106c7318 10.18.1.28:6379@16379 slave da7416ac01c0d2a7766bb874d2d3fdc21e616a38 0 1760600186553 7 connected
# 6ecf38ed5f29e25d5a4737a8d78d3b48ddbce013 10.18.1.27:6379@16379 myself,slave ed918a2d51e9aff8ff8dea9cebceda2a06039bf8 0 1760600184000 8 connected

# 3. MySQL MGR状态:
# mysql: [Warning] Using a password on the command line interface can be insecure.
# +---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+
# | CHANNEL_NAME              | MEMBER_ID                            | MEMBER_HOST | MEMBER_PORT | MEMBER_STATE | MEMBER_ROLE | MEMBER_VERSION | MEMBER_COMMUNICATION_STACK |
# +---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+
# | group_replication_applier | 2adbe5f4-949e-11f0-bb49-525400e3a344 | 10.18.1.27  |        3306 | ONLINE       | SECONDARY   | 8.0.40         | MySQL                      |
# | group_replication_applier | 4013f406-949e-11f0-bb5e-5254004bcca7 | 10.18.1.29  |        3306 | ONLINE       | PRIMARY     | 8.0.40         | MySQL                      |
# | group_replication_applier | b59db2c5-9500-11f0-bbb8-525400340691 | 10.18.1.28  |        3306 | ONLINE       | SECONDARY   | 8.0.40         | MySQL                      |
# +---------------------------+--------------------------------------+-------------+-------------+--------------+-------------+----------------+----------------------------+

# 4. etcd集群状态:
# 10.18.1.27:2379, 80014da14e2de26, 3.5.16, 655 kB, false, 28, 1319
# 10.18.1.28:2379, 15c7da2f2689992c, 3.5.16, 651 kB, true, 28, 1319
# 10.18.1.29:2379, 25d5e6ef54288e7a, 3.5.16, 651 kB, false, 28, 1319

# 5. MySQL Router连接测试:
# mysql: [Warning] Using a password on the command line interface can be insecure.
# +-------------+
# | @@server_id |
# +-------------+
# |           3 |
# +-------------+
# === 开始读写测试 ===
# 1. Redis写测试:
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# OK
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# OK
# 2. Redis读测试:
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# "value_1760600187"
# Warning: Using a password with '-a' or '-u' option on the command line interface may not be safe.
# "value_1760600187"

# 3. MySQL写测试:
# mysql: [Warning] Using a password on the command line interface can be insecure.
# ERROR 1062 (23000) at line 5: Duplicate entry '1' for key 'test_table.PRIMARY'
# 4. MySQL读测试:
# mysql: [Warning] Using a password on the command line interface can be insecure.
# +----+-----------+---------------------+
# | id | data      | timestamp           |
# +----+-----------+---------------------+
# |  1 | test_data | 2025-10-16 07:30:57 |
# +----+-----------+---------------------+

# 5. etcd写测试:
# OK
# 6. etcd读测试:
# test_key
# etcd_value_1760600187
# === 数据一致性验证 ===
# 1. Redis数据一致性:
# 节点 10.18.1.27: test_key = value_1760600187
# 节点 10.18.1.28: test_key = value_1760600187
# 节点 10.18.1.29: test_key = value_1760600187

# 2. MySQL数据一致性:
# 节点 10.18.1.27: 记录数 = 1
# 节点 10.18.1.28: 记录数 = 1
# 节点 10.18.1.29: 记录数 = 1

# 3. etcd数据一致性:
# 节点 10.18.1.27: test_key = test_key
# etcd_value_1760600187
# 节点 10.18.1.28: test_key = test_key
# etcd_value_1760600187
# 节点 10.18.1.29: test_key = test_key
# etcd_value_1760600187
# === 集群测试完成 ===
# all node ok