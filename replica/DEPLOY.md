# replica 主备容灾环境部署手册

- 适用目录：`/home/sder/ha/replica`（脚本内路径全部硬编码为此目录，换路径需全局替换）
- 目标拓扑：2 节点 + 1 VIP
- 环境基线：Ubuntu / Docker 24.0.7 / Compose v2.21.0 / keepalived 2.2.4
- 镜像：`mysql:8.0`、`redis:6.0.9`、`etcd:latest`（已在两台机器上）

---

## 0. 部署前必须确认的 5 件事

### 0.1 端口与 VRID 冲突：TiDB 已停机，当前不冲突

（2026-11-06 复核）两台节点上的 TiDB 容器与 keepalived 均已停止，2379/2380/3306/6379/23790/23800 全部空闲，可以按标准配置部署。

仍需注意：

- `/etc/keepalived/keepalived.conf` 里的 TiDB `VI_TIDB`（vrid 51 / VIP 10.18.1.100）**已在 2026-11-06 替换为 replica 专用配置**（备份见同目录 `keepalived.conf.bak.*`），双端 `keepalived -t` 均通过。TiDB 若将来恢复，需要重新追加 `VI_TIDB`，且 replica 保持 vrid **251**（不能用 51）。
- 若 TiDB 将来重新启动，.28 上的 PD 会重新占用 `127.0.0.1:2379`；届时把 .28 的 etcd 监听改成节点 IP 即可：`ETCD_LISTEN_CLIENT_URLS=http://10.18.1.28:2379`（已验证可绑定）。

### 0.2 keepalived 当前已停止，配置已就绪

- 两台 `systemctl is-active keepalived` 均为 inactive，可以直接开始部署。
- 配置已替换为 replica 专用版（无 `VI_TIDB`），脚本经 `/etc/keepalived/replica-runner.sh` 转发，语法检查通过。
- `global_defs` 开启了 `enable_script_security`，**不能**直接把 `/home/sder` 下的脚本交给 keepalived（即使 chown root 也会被判 insecure），必须用 runner（见 7.1）。

### 0.3 两台优先级必须不同

仓库里只有一份 keepalived.conf（priority 100）。部署时：.27 = 150，.28 = 100。

### 0.4 数据是否保留

现有数据（2026-11-06 实测）：

| 节点 | MySQL | 用户库 | 最后写入 | Redis | etcd |
|---|---|---|---|---|---|
| 10.18.1.27 | 201 MB | 无（仅 mysql/sys/performance_schema） | 2026-02-11 | 空 | 62 MB（etcd1） |
| 10.18.1.28 | 858 MB | `lems-server`、`ha_switch_test` | 2026-01-19 | 12 KB | 123 MB（etcd2） |

结论：**.28 是唯一有业务数据的节点**（binlog `mysql-bin.000004` 达 612 MB）；.27 的 datadir 没有用户库，基本是空实例。两边从未处于一致的复制关系。

- **保留数据（推荐）**：以 **.28** 为主库。先启动 .28 的 MySQL 并确认可写，再用 5.4 的流程重建 .27（`restore_mysql_slave.sh` 会 dump .28 后清空 .27 的 `data/mysql`）。
- **全新部署 / 可清空**：清空 `data/mysql`、`data/redis`、`data/etcd*` 后按本手册重建。
- etcd 两个数据目录属于同一集群（etcd1/etcd2），可以直接一起启动；etcdvip 无数据卷，重新加入即可。

### 0.5 上线前必须修正的脚本缺陷

见第 10 节。其中 **#1 从库指向被硬编码成 .28**，会导致切到 .27 之后再切回来时复制指向错误，必须先改。

---

## 1. 架构

### 1.1 拓扑

| 节点 | IP | 角色 | 运行组件 |
|---|---|---|---|
| node1 | 10.18.1.27 | 初始 MASTER | mysql / redis(master) / etcd1 / etcdvip |
| node2 | 10.18.1.28 | 初始 BACKUP | mysql(slave) / redis(slave) / etcd2 |
| VIP | 10.18.1.30 | 漂移地址 | 由 keepalived 持有，etcdvip 绑定其 23790 |

- keepalived：host 层运行，不是容器；`unicast` 模式，只在两台之间发 VRRP。
- MySQL：单主单从，GTID + ROW + `log-slave-updates`。
- Redis：单主单从，AOF，角色由 notify 脚本用 `SLAVEOF` 切换。
- etcd：3 成员静态集群（etcd1 / etcd2 / etcdvip），etcdvip 成员只跟随 VIP 所在节点启动，为客户端提供 `VIP:23790` 这个稳定入口。

### 1.2 端口清单（全部 host 网络）

| 组件 | 端口 | 说明 |
|---|---|---|
| MySQL | 3306 | 通过 VIP 对外提供服务 |
| Redis | 6379 | 通过 VIP 对外提供服务 |
| etcd | 2379 / 2380 | 客户端 / 集群通信 |
| etcdvip | 23790 / 23800 | 客户端 / 集群通信，仅主节点 |
| keepalived | 112 (VRRP) | 仅两台之间 unicast |

### 1.3 切换时各组件做什么

| 状态 | 触发脚本 | 动作 |
|---|---|---|
| 成为 MASTER | `notify_master.sh` | MySQL：`STOP SLAVE` → `RESET SLAVE ALL` → `read_only=OFF` → `FLUSH BINARY LOGS`；Redis：`SLAVEOF NO ONE`；etcd：启动 etcdvip 容器 |
| 成为 BACKUP | `notify_slave.sh` | MySQL：`read_only=ON` → `RESET MASTER` → `CHANGE MASTER TO VIP` → `START SLAVE`；Redis：`SLAVEOF VIP 6379`；etcd：停止 etcdvip，重启 etcd |
| FAULT / STOP | 当前未配置 | 见问题 #6，建议也指向 `notify_slave.sh` |

### 1.4 容灾指标

- VIP 漂移：约 3~4 秒（`advert_int 1`，丢 3 个通告）。
- MySQL / Redis 都是异步复制：**RPO > 0**，主库宕机前未复制的事务会丢。
- 切换后客户端必须重连并重试；应用侧建议配连接重试与只读判断。

---

## 2. 系统准备（两台都做）

### 2.1 基础环境

```bash
# 时间必须一致（GTID、etcd 选举都依赖时钟）
sudo timedatectl set-ntp true
timedatectl status

# 确认网卡名与 IP（本环境 ens3）
ip -o -4 addr show ens3

# Docker 与 Compose
docker --version            # 24.0.7
docker compose version      # v2.21.0
sudo systemctl enable --now docker

# keepalived
keepalived -v               # v2.2.4
sudo systemctl enable keepalived
```

### 2.2 防火墙

当前两台 `ufw` 均为 inactive。若开启，需放行：

```bash
sudo ufw allow 112/udp          # VRRP（unicast）
sudo ufw allow 3306/tcp
sudo ufw allow 6379/tcp
sudo ufw allow 2379,2380/tcp
sudo ufw allow 23790,23800/tcp
```

### 2.3 目录与代码

```bash
cd /home/sder/ha/replica

# 代码（路径必须是 /home/sder/ha/replica）
git pull

# 数据与日志目录
mkdir -p data/mysql data/redis data/etcd1 data/etcd2 logs

# 全新部署时清空旧数据（谨慎！确认 0.4 的结论后再执行）
# sudo rm -rf data/mysql/* data/redis/* data/etcd1/* data/etcd2/*
```

> `logs/` 由 keepalived（root）写；`data/` 由容器写，属主 root 也正常。

### 2.4 SSH 免密（只有重建从库脚本需要）

`restore_mysql_slave.sh` 通过 `ssh sder@...` 在对端执行 mysqldump，需要 .27 与 .28 之间免密，且 sder 在 docker 组：

```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519   # 已有则跳过
ssh-copy-id sder@10.18.1.28                        # .27 上执行
ssh-copy-id sder@10.18.1.27                        # .28 上执行
ssh 10.18.1.28 docker ps                           # 验证免密 + docker 权限
```

---

## 3. 节点差异化配置

### 3.1 参数对照表

| 配置项 | 10.18.1.27 | 10.18.1.28 |
|---|---|---|
| MySQL `--server-id` | 27 | 28 |
| etcd `ETCD_NAME` | etcd1 | etcd2 |
| etcd 数据目录 | `./data/etcd1` | `./data/etcd2` |
| `ETCD_ADVERTISE_CLIENT_URLS` | `http://10.18.1.27:2379` | `http://10.18.1.28:2379` |
| `ETCD_LISTEN_CLIENT_URLS` | `http://0.0.0.0:2379` | `http://0.0.0.0:2379`（TiDB 停机后无冲突；TiDB 恢复时改成节点 IP） |
| `ETCD_INITIAL_ADVERTISE_PEER_URLS` | `http://10.18.1.27:2380` | `http://10.18.1.28:2380` |
| keepalived priority | 150 | 100 |
| `unicast_src_ip` / `unicast_peer` | .27 / .28 | .28 / .27 |
| Redis 角色 | master | slave of 10.18.1.27 |

### 3.2 `.env`

`docker-compose.yaml` 里**只用到** `${ETCD_CLUSTER_STATE}`。`NODEID` / `NODEIP` / `NODELIST` / `REDIS_PASSWORD` 都是 cluster 版本遗留、当前无效，改了不会有任何效果。

```bash
# etcd 首次初始化阶段（见 4.1）
ETCD_CLUSTER_STATE=new
# 集群建立后改回
ETCD_CLUSTER_STATE=existing
```

### 3.3 `docker-compose.yaml`（.28 需要修改）

仓库里这份是 .27 的版本。.28 上按 3.1 修改以下几处：

```yaml
# .28: mysql
- --server-id=28

# .28: etcd
- ETCD_NAME=etcd2
- ETCD_ADVERTISE_CLIENT_URLS=http://10.18.1.28:2379
- ETCD_INITIAL_ADVERTISE_PEER_URLS=http://10.18.1.28:2380
volumes:
  - ./data/etcd2:/etcd-data

# 若 TiDB 恢复运行，.28 需再加一行（PD 占用 127.0.0.1:2379）
# - ETCD_LISTEN_CLIENT_URLS=http://10.18.1.28:2379
# 并把 healthcheck 的 endpoint 同步改成该地址
```

`ETCD_INITIAL_CLUSTER` 两台保持一致，不要改：

```
etcd1=http://10.18.1.27:2380,etcd2=http://10.18.1.28:2380,etcdvip=http://10.18.1.30:23800
```

> `config/redis.conf` 虽然挂载进了容器，但容器启动命令把所有参数都写成了命令行参数，**这个文件不会被加载**，改它无效。

### 3.4 不要执行 `init.sh`

`replica/init.sh` 会去改 `mysql/config/my.cnf` 和 `mysqlrouter/config/mysqlrouter.conf`（replica 目录下不存在这两个路径），加上 `set -e`，会直接中断。它属于 cluster 版本的脚本，节点差异请直接改 `docker-compose.yaml`。

---

## 4. 启动 etcd 集群

### 4.1 首次 bootstrap

两台**同时**设置 `ETCD_CLUSTER_STATE=new`，然后启动：

```bash
cd /home/sder/ha/replica
sed -i 's/^# *ETCD_CLUSTER_STATE=.*/ETCD_CLUSTER_STATE=new/' .env
docker compose up -d etcd
```

> initial-cluster 里列了 3 个成员，启动 2 个即可达到多数派（2/3），etcdvip 稍后按需启动。
> 若 etcdvip 容器启动即退出并报 `flag provided but not defined: -learner`，说明 `ETCD_LEARNER` 不是 etcd 服务端参数，删掉该环境变量即可（见问题 #8）。

### 4.2 验证

```bash
docker exec etcd etcdctl \
  --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 \
  endpoint health

docker exec etcd etcdctl \
  --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 \
  endpoint status --write-out=table

docker exec etcd etcdctl \
  --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379 \
  member list
```

期望：health 全为 `healthy`，status 表中 2 个端点，其中恰好 1 个 `IS LEADER=true`；member list 显示 3 个成员（etcdvip 此时未启动属正常）。

确认无误后把状态改回，避免下次重建容器时再次 bootstrap：

```bash
sed -i 's/^ETCD_CLUSTER_STATE=new/ETCD_CLUSTER_STATE=existing/' .env
```

### 4.3 etcdvip（跟随 VIP 的成员）

- 只在持有 VIP 的节点启动，由 `etcd_notify_master.sh` 执行 `docker compose up -d etcdvip`。
- 失去 VIP 时由 `etcd_notify_slave.sh` 执行 `docker compose down etcdvip`。
- **它没有数据卷**（compose 里被注释掉了）：容器被 `down` 移除后数据目录一起丢失，重新在新节点启动时的成员身份行为必须在演练中验证。
- 由于 `initial-cluster` 已把它列为成员，它实际是**有投票权的普通成员**，`ETCD_LEARNER=true` 不改变这一点。这一点对可用性有利：一个应用节点宕机时仍有 2/3 多数派。
- 如果验证发现它无法稳定重建，建议改用 compose 里注释掉的 `etcd-proxy` 方案（无状态代理，不参与成员变更）。

---

## 5. MySQL 主从

### 5.1 启动

```bash
cd /home/sder/ha/replica
docker compose up -d mysql
docker compose ps mysql
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT @@server_id, @@read_only, @@gtid_mode;"
```

### 5.2 确定主库

新部署时以 .27 为主库（VIP 初始也在这台）。保留旧数据时以数据较新的一边为主库。

```bash
# 在主库上确认可写
docker exec -i mysql mysql -uroot -p's<9!Own1z4' \
  -e "SELECT @@server_id, @@read_only, @@super_read_only; SHOW MASTER STATUS\G"
```

### 5.3 从库接入复制

在 .28 上执行（此时 VIP 还没起来，先直连 .27；keepalived 启动后 notify 脚本会把源改成 VIP）：

```bash
docker exec -i mysql mysql -uroot -p's<9!Own1z4' <<'EOF'
SET GLOBAL super_read_only=OFF;
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='10.18.1.27',
  MASTER_USER='root',
  MASTER_PASSWORD='s<9!Own1z4',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
START SLAVE;
SET GLOBAL read_only=ON;
SET GLOBAL super_read_only=ON;
EOF
```

验证（.28）：

```bash
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" | \
  grep -E "Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Master_Host"
```

期望：`Slave_IO_Running: Yes`、`Slave_SQL_Running: Yes`、`Master_Host: 10.18.1.27`。

> MySQL 8.0.23+ 推荐写法是 `CHANGE REPLICATION SOURCE TO SOURCE_HOST=...`，`CHANGE MASTER TO` 仍可用但会有弃用警告。仓库脚本用的都是旧写法，两者等价。

### 5.4 保留旧数据时的重建

两边 GTID 集可能已经分叉（历史主从互换过），`MASTER_AUTO_POSITION=1` 会报错。此时从主库做一次全量重建：

```bash
# 1) 在主库导出（含 GTID 信息）
ssh sder@10.18.1.27 "docker exec mysql mysqldump -uroot -p's<9!Own1z4' \
  --all-databases --single-transaction --master-data=2 --set-gtid-purged=ON \
  --routines --events > /tmp/master_dump.sql"

# 2) 拷到从库并导入
scp sder@10.18.1.27:/tmp/master_dump.sql /tmp/master_dump.sql
docker exec -i mysql mysql -uroot -p's<9!Own1z4' < /tmp/master_dump.sql

# 3) 按 5.3 重新配置复制
```

仓库的 `scripts/restore_mysql_slave.sh` 做的就是这个流程，但它把主从 IP 写死成 .28/.27、会 `rm -rf data/mysql/*`、且依赖 ssh 免密，只适合"确认当前主库是 .28"的场景，使用前必须改。

### 5.5 复制延迟与参数

- `binlog_format=ROW`、`gtid_mode=ON`、`enforce-gtid-consistency=ON`、`log-slave-updates=ON`，均已在 compose 中。
- 复制是异步的，关注 `Seconds_Behind_Master`；如需更低 RPO 需另上半同步（当前未启用）。

---

## 6. Redis 主从

```bash
cd /home/sder/ha/replica
# 两台都启动
docker compose up -d redis

# 在 .28 上配置为 .27 的从库
docker exec -i redis redis-cli -a 'A8K5h7+6!?' SLAVEOF 10.18.1.27 6379
```

验证：

```bash
# .27
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication | \
  grep -E "role:|connected_slaves|slave0"

# .28
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication | \
  grep -E "role:|master_host|master_link_status"
```

期望：.27 `role:master` 且 `connected_slaves:1`；.28 `role:slave`、`master_host:10.18.1.27`、`master_link_status:up`。

> Redis 密码含特殊字符，命令行务必用单引号包住。生产环境建议改用 `REDISCLI_AUTH` 环境变量，避免密码出现在 `ps` 里。

---

## 7. keepalived

### 7.1 脚本权限（enable_script_security 要求）

**不要** `chown root` 仓库里的脚本。`enable_script_security` 会校验脚本路径上每一级目录的属主，`/home/sder` 属于普通用户，脚本放在下面即使 `root:root + 755` 也仍会被判定为 insecure（实测 `keepalived -t` 退出码 5：`Disabling track script chk_mysql_ha due to insecure`）。

正确做法是放一个 root 拥有的转发脚本在 `/etc/keepalived` 下：

```bash
sudo tee /etc/keepalived/replica-runner.sh >/dev/null <<'EOF'
#!/bin/bash
BASE=/home/sder/ha/replica/scripts
case "${1:-}" in
    check)  exec "$BASE/check_mysql_status.sh" ;;
    master) exec "$BASE/notify_master.sh" ;;
    backup) exec "$BASE/notify_slave.sh" ;;
    *) echo "usage: $0 {check|master|backup}" >&2; exit 2 ;;
esac
EOF
sudo chown root:root /etc/keepalived/replica-runner.sh
sudo chmod 755 /etc/keepalived/replica-runner.sh
```

`global_defs` 里的 `script_user root` 保证以 root 身份执行（脚本里有 `docker exec`、写 `/var/run`、`ip addr`，不能用 sder 跑）。

### 7.2 替换 keepalived 配置

TiDB 已永久下线，所以不再追加 `VI_TIDB`，而是**整份替换**成 replica 专用配置：

```bash
sudo cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak.$(date +%Y%m%d%H%M%S)
# .27 用 keepalived.conf，.28 用 keepalived.28.conf
sudo cp /home/sder/ha/replica/scripts/keepalived.conf /etc/keepalived/keepalived.conf   # .28: keepalived.28.conf
```

两份文件的唯一差异：`priority`（.27=150 / .28=100）、`unicast_src_ip`、`unicast_peer`。关键段落：

```
global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_mysql_ha {
    script "/etc/keepalived/replica-runner.sh check"
    interval 5
    timeout 10
    fall 3
    rise 2
    user root
}

vrrp_instance VI_MYSQL_HA {
    state BACKUP            # 两端都用 BACKUP + nopreempt，靠 priority 选主，恢复后不抢回
    interface ens3
    virtual_router_id 251
    priority 150            # .28 = 100
    advert_int 1
    nopreempt

    unicast_src_ip 10.18.1.27
    unicast_peer { 10.18.1.28 }

    authentication { auth_type PASS  auth_pass Rp251ha }

    virtual_ipaddress { 10.18.1.30/24 dev ens3 }

    track_script { chk_mysql_ha }

    notify_master "/etc/keepalived/replica-runner.sh master"
    notify_backup "/etc/keepalived/replica-runner.sh backup"
    notify_fault  "/etc/keepalived/replica-runner.sh backup"
    notify_stop   "/etc/keepalived/replica-runner.sh backup"
}
```

> `track_script` 不配 `weight`：检查失败时实例直接进 FAULT、释放 VIP，备节点才能接管。
> `notify_fault` / `notify_stop` 是原仓库配置里缺失的，补上才能保证 keepalived 异常退出时 MySQL/Redis 被降级。
> 健康检查语义（`check_mysql_status.sh`）：**MASTER 侧** MySQL 不可用或 `read_only != 0` 才返回 1；**BACKUP 侧永远返回 0**，否则备节点会自己进 FAULT、无法接管。提升过程中靠 `/var/run/replica_promoting` 标记给出 120 秒宽限期，避免"先拿 VIP 后改 read_only"的时序误判。

### 7.3 校验并加载

```bash
# 语法检查（必须是 0；非 0 且报 "due to insecure" 说明还在用 /home 下的脚本）
sudo keepalived -t -f /etc/keepalived/keepalived.conf; echo "exit=$?"

# 单独跑一次健康检查，确认 runner 与脚本链路正常（BACKUP 侧返回 0 属正常）
sudo /etc/keepalived/replica-runner.sh check; echo "check-exit=$?"

# 配置已整份替换（无 VI_TIDB），直接启动
sudo systemctl start keepalived
```

**顺序很重要**：

1. 先在 **.27** 上启动，等待它拿到 `10.18.1.30`（约 3~4 秒）。
2. 确认 VIP 已在 .27 后，再在 **.28** 上启动，它会以 BACKUP 状态进入。
3. 若反了，.28 会先拿到 VIP，之后由于 `nopreempt` 不会归还。

```bash
# 确认 VIP 位置
ip -o -4 addr show ens3 | grep 10.18.1.30

# 确认 keepalived 状态与日志
sudo systemctl status keepalived
sudo journalctl -u keepalived -n 50 --no-pager
sudo tcpdump -i ens3 -n vrrp -c 5

# 脚本自身日志
tail -f /home/sder/ha/replica/logs/keepalived-wrapper.log
```

---

## 8. 端到端验收清单

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 1 | VIP 只在一台 | `ip -o -4 addr show ens3 \| grep 10.18.1.30` | 仅 .27 有 |
| 2 | MySQL 可写 | `mysql -h 10.18.1.30 -uroot -p's<9!Own1z4' -e "SELECT @@server_id, @@read_only"` | server_id=27，read_only=0 |
| 3 | 从库复制正常 | 在 .28 `SHOW SLAVE STATUS\G` | IO/SQL 均 Yes，延迟 0 |
| 4 | 从库只读 | 在 .28 `SELECT @@read_only, @@super_read_only` | 1 / 1 |
| 5 | Redis 主从 | 两台 `info replication` | master 1 个 slave；slave link up |
| 6 | etcd 健康 | `endpoint health` | 全部 healthy |
| 7 | etcd leader 唯一 | `endpoint status --write-out=table` | 恰好 1 个 true |
| 8 | etcdvip | 在主节点 `docker ps \| grep etcdvip`；`etcdctl --endpoints=http://10.18.1.30:23790 endpoint status` | 容器运行、端点可查 |
| 9 | 备节点无 etcdvip | 在 .28 `docker ps \| grep etcdvip` | 无输出 |
| 10 | 端口监听 | `sudo ss -lntp \| grep -E ':(3306\|6379\|2379\|2380\|23790\|23800)\b'` | 全部有进程 |
| 11 | 脚本日志 | `tail -50 /home/sder/ha/replica/logs/keepalived-wrapper.log` | 无 `command not found` / 无报错 |
| 12 | 已无 TiDB 实例 | `grep -c VI_TIDB /etc/keepalived/keepalived.conf` | 0 |
| 13 | 健康检查链路 | `sudo /etc/keepalived/replica-runner.sh check; echo $?` | 0 |

---

## 9. 切换演练

### 9.1 计划内切换（主 → 备）

```bash
# 1) 在持有 VIP 的节点（假定 .27）执行
sudo systemctl stop keepalived

# 2) 约 5~8 秒后在 .28 检查
ip -o -4 addr show ens3 | grep 10.18.1.30
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SELECT @@server_id, @@read_only; SHOW SLAVE STATUS\G"
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication | grep role:
docker ps | grep etcdvip

# 3) 业务侧验证（写走 VIP）
mysql -h 10.18.1.30 -uroot -p's<9!Own1z4' \
  -e "CREATE DATABASE IF NOT EXISTS dr_test; CREATE TABLE IF NOT EXISTS dr_test.t(id INT PRIMARY KEY AUTO_INCREMENT, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP); INSERT INTO dr_test.t VALUES ();"
```

期望：VIP 在 .28；MySQL `server_id=28, read_only=0`、无从库状态；Redis `role:master`；etcdvip 在 .28 运行；写入成功。

### 9.2 回切（原主恢复）

```bash
# 在 .27 上重新启动 keepalived
sudo systemctl start keepalived

# 等待 10 秒后检查：.27 应处于 BACKUP（nopreempt 不抢回 VIP）
ip -o -4 addr show ens3 | grep 10.18.1.30        # 仍然在 .28
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" | grep -E "Master_Host|Slave_IO_Running"
```

期望：.27 上 `Master_Host` 为 `10.18.1.30`（VIP），复制 Running。

### 9.3 非计划故障

- 节点级故障（关机 / 断网）会触发 VIP 漂移。
- 单组件故障：`check_mysql_status.sh` 已修正，MASTER 侧 `docker stop mysql` 会连续 3 次（`fall 3`，约 15 秒）检查失败 → 实例进 FAULT、释放 VIP → 备节点接管。BACKUP 侧 MySQL 或复制异常**不会**导致自身 FAIL（只告警 + 异步重建），这是刻意设计。
- 演练后如需重建备库：查看 `logs/keepalived-wrapper.log` 中的 `异步执行从库重建` 与 `=== 重建完成 ===`，或手工执行 `restore_mysql_slave.sh`。

### 9.4 仓库自带测试套件

```bash
cd /home/sder/ha/replica/scripts/mysql_ha_test
# 依赖：sysbench、mysql 客户端（当前 10.18.1.33 上已具备），且能 ssh 到两台节点
./run_all_tests.sh
# 结果：logs/ 下日志，reports/ 下 HTML 报告
```

`config.sh` 里的节点列表、VIP、密码需与实际一致；测试日志目录已在 `.gitignore` 中。

### 9.5 切换失败的回滚

```bash
# 停止切换流程
sudo systemctl stop keepalived            # 两台

# 恢复原主库写入（仅在确认没有脑裂的情况下）
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SET GLOBAL read_only=OFF;"

# 需要重建从库时
/home/sder/ha/replica/scripts/restore_mysql_slave.sh
```

---

## 10. 已知问题与修正状态

> 状态截至 2026-11-06：✅ = 已修复并下发到两台节点；🔶 = 部分缓解；⬜ = 未处理。

| # | 位置 | 问题 | 影响 | 状态 / 处理 |
|---|---|---|---|---|
| 1 | `mysql_notify_slave.sh` | `MASTER_HOST` 硬编码为 `10.18.1.28` | 主库是 .27 时降级节点复制指向错误 | ✅ 改为 `$MYSQL_VIP`（10.18.1.30） |
| 2 | `notify_slave.sh` | 未 `source base.sh` 却用 `_ts_pipe` | 日志丢失、返回 127 | ✅ 已 source 并校验各子脚本返回码 |
| 3 | `check_mysql_status.sh` | 所有分支 `exit 0`；lock + 计数导致检测延迟翻倍 | MySQL 挂掉不切换 | ✅ MASTER 失败 `exit 1`；BACKUP 恒 0；改用 `flock -n` |
| 4 | `keepalived.conf` | `interval 60`、`timeout 4000`、`fall/rise` 注释掉 | 检测周期过长 | ✅ 5 / 10 / 3 / 2 |
| 5 | `keepalived.conf` | 只有一份、priority 相同、vrid 51 | 与 TiDB 冲突、选举不确定 | ✅ vrid 251；.27=150 / .28=100 两份配置 |
| 6 | `keepalived.conf` | 缺 `notify_fault` / `notify_stop` | 异常时组件不降级 | ✅ 均指向 `runner backup` |
| 7 | `mysql_notify_slave.sh` | 降级时 `RESET MASTER` | 清空 binlog，破坏 GTID 追溯 | ✅ 删除；改为 `RESET SLAVE ALL` + `CHANGE MASTER` |
| 8 | `docker-compose.yaml:112` | `ETCD_LEARNER` 非合法服务端参数，且 etcdvip 已在 `initial-cluster` | 可能启动失败 | ⬜ 首次启动时验证，报错则删除该变量 |
| 9 | `docker-compose.yaml:116-118` | etcdvip 没有数据卷 | `down` 后成员数据丢失 | 🔶 脚本改用 `compose stop`，数据保留；长期建议换 etcd-proxy |
| 10 | `check_mysql_status.sh` | 调 `mail` 但两台都没装 | 告警静默失败 | 🔶 已加 `command -v mail` 判断并限频写日志；建议装 mailutils 或改 webhook |
| 11 | `init.sh` | 编辑不存在的文件 + `set -e` | 直接失败 | ⬜ 不使用（见 3.4） |
| 12 | `restore_mysql_slave.sh` | IP/路径写死、无条件清空 `data/mysql` | 误用丢数据 | ✅ 源改 VIP；dump 为空即中止；持有 VIP 时拒绝执行；异步调用 |
| 13 | 全局 | 路径与密码硬编码 | 迁移/改密成本高 | 🔶 统一收敛到 `scripts/base.sh`；仍需改密时只改一处 |
| 14 | `config/redis.conf` | 挂载但被命令行参数覆盖 | 改文件无效 | ⬜ 删除挂载或改为单入口 |

---

## 11. 日常运维命令

```bash
# 服务
cd /home/sder/ha/replica
docker compose ps
docker compose up -d
docker compose logs -f --tail=100 mysql

# 当前主库（通过 VIP）
mysql -h 10.18.1.30 -uroot -p's<9!Own1z4' -e "SELECT @@server_id, @@read_only;"

# 复制状态
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" | \
  grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master"

# Redis
docker exec -i redis redis-cli -a 'A8K5h7+6!?' info replication | head -20

# etcd
docker exec etcd etcdctl --endpoints=http://10.18.1.27:2379,http://10.18.1.28:2379,http://10.18.1.30:23790 endpoint status -w table

# VIP / keepalived
ip -o -4 addr show ens3 | grep 10.18.1.30
sudo systemctl status keepalived
sudo journalctl -u keepalived -f

# 业务切换日志
tail -f /home/sder/ha/replica/logs/keepalived-wrapper.log
tail -f /home/sder/ha/replica/logs/keepalived-mysql.log
tail -f /home/sder/ha/replica/logs/keepalived-redis.log
tail -f /home/sder/ha/replica/logs/etcd-keepalived.log
```

---

## 12. 部署记录（填写后归档）

| 项目 | 内容 |
|---|---|
| 部署日期 | |
| 部署人 | |
| 节点 1 / 节点 2 / VIP | 10.18.1.27 / 10.18.1.28 / 10.18.1.30 |
| 初始主库 | |
| 数据是否保留 | 是 / 否 |
| 端口冲突处理 | |
| 已修正的问题编号 | |
| 切换演练结果 | |
| 遗留问题 | |

---

## 13. 优化建议

### P0：影响切换正确性 —— 已全部实施（2026-11-06）

| 项 | 原问题 | 已实施内容 |
|---|---|---|
| 提升前排空 relay log | 直接 `STOP SLAVE` + `RESET SLAVE ALL` | `mysql_notify_master.sh` 先 `STOP SLAVE IO_THREAD`，轮询 `Slave_SQL_Running_State` 至 "read all relay log"（最多 30s），再 `STOP SLAVE` / `RESET SLAVE ALL` / `read_only=OFF` / `FLUSH BINARY LOGS`；结束时校验 `@@global.read_only=0`，否则 `exit 1` |
| 降级时不 `RESET MASTER` | 清空 binlog，历史不可追溯 | 两个方向都已去掉 `RESET MASTER`，统一 `RESET SLAVE ALL` + `CHANGE MASTER ... MASTER_AUTO_POSITION=1` |
| 通知脚本不校验结果 | 失败仍打印 finished、返回 0 | `notify_master/slave.sh` 初始化状态位、用 `${PIPESTATUS[0]}` 取真实返回码，任一子脚本失败即 `exit 1`；keepalived 日志可见失败 |
| 锁文件残留 | 锁文件残留导致永久跳过检查 | 改为 `flock -n 9`（fd 9 打开 `/var/run/replica_health_check.lock`），进程退出自动释放 |
| 健康检查判据 | 只判断能否连接 | MASTER 校验 `read_only/super_read_only=0`；BACKUP 校验 `Slave_IO_Running` / `Slave_SQL_Running`，异常时告警 + 限频异步重建；提升期间用 `/var/run/replica_promoting` 给 120s 宽限 |

配套改动：
- `etcd_notify_master/slave.sh` 的健康等待由固定 `sleep` 改为 `etcdctl endpoint health` 轮询，失败返回 1；容器匹配改为精确名（`grep -qx etcd`，不会误匹配 etcdvip）；降级用 `compose stop etcdvip` 保留数据。
- `restore_mysql_slave.sh`：`set -euo pipefail`、持有 VIP 时拒绝执行、dump 为空即中止（清空数据目录前）、就绪/复制状态有界轮询。
- 所有路径/凭据收敛到 `scripts/base.sh`，keepalived 通过 `/etc/keepalived/replica-runner.sh` 调用（见 7.1）。

### P1：脑裂与可用性

- **Redis 防脑裂**：`min-replicas-to-write 1`、`min-replicas-max-lag 10`，网络分区时旧主不会继续接受写。
- **MySQL 看门狗**：每秒检查 VIP 是否在本机，若不在且 `read_only=0` 则强制置只读，覆盖 keepalived 自身异常/被停掉的场景。
- **2 节点 VRRP 没有仲裁**：两台之间网络断开时，双方都可能认为自己是主。建议加第三台仲裁节点或独立心跳网；或直接利用已部署的 etcd 做租约选举。
- **etcdvip 换成 etcd-proxy**：compose 里注释掉的 `etcd-proxy` 是无状态代理，不参与成员变更，可以两个节点常驻、客户端固定连 `VIP:23790`；同时移除 `ETCD_LEARNER`，`initial-cluster` 只保留 etcd1/etcd2。

### P2：运维与安全

| 项 | 建议 |
|---|---|
| 日志轮转 | `.27` 的 `keepalived-wrapper.log` 已 **131 MB**、`.28` 80 MB，且无轮转。给 `/home/sder/ha/replica/logs/*.log` 配 logrotate（按天或 100M，保留 7 份）；容器加 `logging: {max-size: 50m, max-file: 3}` |
| 告警 | `mail` 未安装，日志里的"通知已发送"实际是静默失败。安装 mailutils 或改成 webhook / 企业微信 |
| 备份 | 当前没有定时备份。建议 MySQL 每日全备 + binlog 保留 7 天，etcd 每日 `snapshot save` |
| 凭据 | 密码明文散落在 10+ 个脚本中，复制使用 root。建专用 `repl` 账号（仅 REPLICATION SLAVE），密码集中管理 |
| Redis 启动方式 | 改为 `redis-server /usr/local/etc/redis/redis.conf`，密码不再出现在 `ps` / `docker inspect` |
| 镜像版本 | `etcd:latest` 不固定，建议钉到具体 tag |
| 脚本健壮性 | 顶部加 `set -euo pipefail`，变量加引号，`docker exec` 加 `timeout`，避免永久卡住 |

### P3：测试套件问题（`scripts/mysql_ha_test/`）

| 脚本 | 问题 | 影响 |
|---|---|---|
| `monitor_switch.sh` | 用 `systemctl is-active mysql` 判断 MySQL 状态 | MySQL 在容器里，主机上永远 `inactive`，监控恒显示"停止" |
| `prepare_test.sh` / `run_switch_test.sh` | 用 `SELECT @@hostname` 与 `ssh host hostname` 比对 | 容器 hostname 是容器 ID，不等于节点主机名，永远匹配不上 → `CURRENT_MASTER` 为空直接退出 |
| `verify_consistency.sh` | 用 `'...' \|\| $SAMPLE_START` 拼字符串 | MySQL 中 `\|\|` 是逻辑或而非拼接，应使用 `CONCAT()` |
| `run_switch_test.sh` | `--mysql-ignore-errors=all` | 切换期间的真实写失败被吞掉，结论偏乐观 |
| 全部 | 缺 `set -o pipefail`，查询失败时变量为空仍继续 | `[ -eq ]` 报错、误判 |
