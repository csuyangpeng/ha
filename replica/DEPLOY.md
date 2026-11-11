# replica 主备容灾环境部署手册

- 适用目录：`/home/sder/ha/replica`（脚本内路径全部硬编码为此目录，换路径需全局替换）
- 目标拓扑：2 节点 + 1 VIP
- 环境基线：Ubuntu / Docker 24.0.7 / Compose v2.21.0 / keepalived 2.2.4
- 镜像：`mysql:8.0`、`redis:6.0.9`、`etcd:latest`（已在两台机器上）

---

## 0. 部署前必须确认的 5 件事

### 0.1 端口与 VRID 冲突：TiDB 已停机，当前不冲突

（2026-11-06 复核）两台节点上的 TiDB 容器与 keepalived 均已停止，2379/2380/3306/6379/23790/23800 全部空闲，可以按标准配置部署。coremgr 使用 8888，部署前确认未被占用（`ss -lntp | grep :8888`）。

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
| node1 | 10.18.1.27 | 初始 MASTER | mysql / redis(master) / etcd1 / etcdvip / coremgr |
| node2 | 10.18.1.28 | 初始 BACKUP | mysql(slave) / redis(slave) / etcd2 / coremgr |
| VIP 组 | `10.18.1.30`（+ 可选 `10.18.1.31` 等） | 整组漂移 | 由 keepalived 持有；第 1 个是数据面 VIP，etcdvip 绑定其 23790 |

- 一个 VRRP 实例承载多个 `virtual_ipaddress`：**整组同漂**，不存在只漂一半的状态。VIP 清单由
  `/etc/keepalived/replica-vips` 统一写入，coremgr 也读这份文件，避免两边配置不一致。
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
| coremgr | 8888 | HA 状态接口 `/coremgr/ha/*`；`/coremgr/ha/health` 供对端查询核心网健康 |
| core NF 探活 | 29510、29502 等 | 各 NF 自带的本地 HTTP 端口，仅 coremgr 从 `127.0.0.1` 探活，不对 VIP 暴露 |

> NF 探活端口以实际部署为准。默认配置里 `nrf` 用 `http://127.0.0.1:29510/health_check`，
> `smf` 用 `http://127.0.0.1:29502/health`，其余 NF 同样按其真实端口填写完整 URL（见 7.4）。

### 1.3 切换时各组件做什么

| 状态 | 触发脚本 | 动作 |
|---|---|---|
| 成为 MASTER | `notify_master.sh` | MySQL：`STOP SLAVE` → `RESET SLAVE ALL` → `read_only=OFF` → `FLUSH BINARY LOGS`；Redis：`SLAVEOF NO ONE`；etcd：启动 etcdvip 容器 |
| 成为 BACKUP | `notify_slave.sh` | MySQL：`read_only=ON` → `RESET MASTER` → `CHANGE MASTER TO VIP` → `START SLAVE`；Redis：`SLAVEOF VIP 6379`；etcd：停止 etcdvip，重启 etcd |
| FAULT / STOP | `replica-runner.sh fault` | 按 BACKUP 处理：释放 VIP，MySQL/Redis 回到从库角色 |
| 健康判定 | `check_mysql_status.sh` | MASTER：MySQL 可用/可写 → **核心网聚合 verdict 就绪** → 通过；BACKUP：始终 exit 0 |

切换判定顺序（MASTER 侧）：

1. MySQL 硬故障（进程/连接/可写性）→ exit 1，释放 VIP；若对端核心网明确未就绪，则暂不释放（见 7.4）。
2. MySQL 正常后查 `check_core_status.sh gate`：`enforce=0`、verdict 过期或本地只是 grace → 不切换；critical NF 确认故障且**对端 ready=1** → exit 1。
3. 对端也异常 → 保持现状并告警，避免把 VIP 交给一个同样不可用的节点。

### 1.4 容灾指标

- VIP 漂移：keepalived 层面约 3~4 秒（`advert_int 1`，丢 3 个通告）。
- 核心网参与判定后的整链路：coremgr 连续 2 次探测（10s）+ keepalived `fall 3 × interval 5`（15s），最坏约 25~30 秒才触发倒换。这是有意的去抖，避免 NF 抖动造成来回切。
- 多 VIP 整组同漂，不提供单 VIP 独立漂移。
- MySQL / Redis 都是异步复制：**RPO > 0**，主库宕机前未复制的事务会丢。
- 切换后客户端必须重连并重试；应用侧建议配连接重试与只读判断。

---

## 2. 系统准备（两台都做）

### 2.1 基础环境

```bash
# 时间同步（无外网方案见 2.5）
timedatectl status
timedatectl show-timesync 2>/dev/null | grep -E 'ServerName|ServerAddress'

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
sudo ufw allow 123/udp          # 内部 NTP（见 2.5）
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

### 2.5 时间同步（无外网方案）

#### 现状与问题

2026-11-06 实测：两台都是 `systemd-timesyncd`，上游均为公网 `ntp.ubuntu.com`（DNS 轮询，各自解析到不同 IP）。内网候选 `10.18.1.254`（网关）、`10.18.1.1`、`10.18.1.2`、`10.18.1.10` 探测 `123/udp` **均无 NTP 应答**。

因此一旦断外网：
- 两台都失去时间源，只能靠各自 RTC 自由运行，日漂移可达数百毫秒到数秒；
- `timedatectl` 仍显示 `System clock synchronized: yes`，这是最后一次同步的历史状态，**不代表当前还有时间源**；
- 时钟不一致会直接影响 etcd 选举超时、日志时序、TLS 证书校验（MySQL GTID 本身不依赖时钟，但业务写入顺序依赖）。

`systemd-timesyncd` 只能做客户端、不能对外授时，所以无外网场景必须改用 **chrony**（或 ntpd）自建内部时间源。

#### 推荐方案：固定主备授时（.27 为主，.28 为备）

| 角色 | 节点 | 配置要点 |
|---|---|---|
| NTP 主 | 10.18.1.27 | 无上游，`local stratum 10` 用本机时钟授时，`allow 10.18.1.0/24` |
| NTP 备 | 10.18.1.28 | `server 10.18.1.27 iburst`，`local stratum 12` 兜底，`allow 10.18.1.0/24` |

为什么固定一台当主：内网没有可信时钟源时，任何方案都只能保证"两台相对一致"，不能保证绝对准确。固定 .27 为主可以避免两台互相比较时出现来回选举；.28 的 `local stratum 12` 保证 .27 宕机后仍能继续对客户端授时。

> **NTP 主备与 MySQL/keepalived 主备无关**，不需要随 VIP 漂移。当前业务数据在 .28、切换后 MySQL 主库可能是 .28，但 NTP 主仍固定 .27，两者互不影响。

#### 步骤 1：安装 chrony（务必在有外网时先做）

chrony 与 `systemd-timesyncd` 冲突（都提供 `time-daemon`），安装时 apt 会自动移除 timesyncd：

```bash
sudo apt-get install -y chrony
systemctl is-active chrony                 # active
systemctl is-active systemd-timesyncd      # inactive（已移除）
```

已提前把安装包缓存到两台机器的 `/var/cache/apt/archives/`；完全离线时可用：

```bash
sudo dpkg -i /var/cache/apt/archives/chrony_4.2-2ubuntu2.1_amd64.deb
sudo apt-get -f install -y                 # 补齐本地依赖（正常应无额外下载）
```

若内网本来就有授时服务器（域控、核心交换机等），先用它，不必自建：

```bash
sudo chronyd -Q 'server 10.18.1.254 iburst'   # 有应答并输出 offset 即说明是可用 NTP 源
```

#### 步骤 2：配置

**10.18.1.27** `/etc/chrony/chrony.conf`（先备份原文件）：

```
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
rtcsync
makestep 1.0 3

# 内网无外网：以本机时钟为基准授时
local stratum 10
allow 10.18.1.0/24

# 恢复外网后可取消注释；公网源 stratum 更低，会自动优先
# pool ntp.ubuntu.com iburst
```

**10.18.1.28** `/etc/chrony/chrony.conf`：

```
driftfile /var/lib/chrony/chrony.drift
logdir /var/log/chrony
rtcsync
makestep 1.0 3

# 同步 NTP 主
server 10.18.1.27 iburst minpoll 4 maxpoll 6
# .27 不可达时用本机时钟兜底授时（stratum 高于主，主恢复后自动切回）
local stratum 12
allow 10.18.1.0/24

# pool ntp.ubuntu.com iburst
```

```bash
sudo mkdir -p /var/log/chrony
sudo systemctl restart chrony
sudo systemctl enable chrony
```

> 配置里必须写 **IP**，不能写域名——无外网时 DNS 解析会失败。
> 若 .28 上也要让其他主机通过 VIP `10.18.1.30` 授时，无需额外配置：chrony 监听 `0.0.0.0:123`，VIP 漂移过来后自然应答。

#### 步骤 3：验证

```bash
# .27：应显示 Reference ID 为本地时钟、Stratum 10
chronyc tracking

# .28：应看到 ^* 10.18.1.27，Stratum 11
chronyc sources -v
chronyc tracking

# 在 .27 上查看有哪些客户端在同步
sudo chronyc clients

# 两台时钟差（应 < 100ms）
ssh 10.18.1.28 'date +%s.%N'; date +%s.%N
```

注意：装 chrony 后 `timedatectl` 的状态字段不再可靠（实测 .27 显示 `NTP service: active` 但 `System clock synchronized: no`，.28 显示 `yes`）——这些字段由 timedated 维护，并不反映 chrony 的同步状态，**属正常现象**。判断授时是否正常只看 `chronyc tracking` / `chronyc sources`（应为 `Leap status : Normal`，`.28` 的源带 `^*`）。

#### 步骤 4：故障与时间跳变

- **.27 宕机**：.28 约 3 个轮询周期（`minpoll 4` ≈ 16s）后判定源不可用，启用 `local stratum 12` 继续授时；期间依靠 RTC 保持精度。
- **.27 恢复**：.28 重新同步 .27。因已过启动初期的 3 次校时窗口，chrony 只做 **slew**（最大约 300 秒/小时），不会瞬间跳变，避免影响 etcd/MySQL。
- **两台同时断电重启**：各自 RTC 漂移可能不同，启动后 .27 先成为源，.28 随后 slew 对齐；开机后建议人工执行一次上面的验证命令。
- **需要立即强制对齐**（例如偏差已达分钟级）：`sudo chronyc makestep`。这会瞬间跳变时间，**etcd 对时间跳变敏感**，应在停 keepalived/etcd 后再做。
- 容器（MySQL/Redis/etcd）共享宿主机时钟，无需单独配置。

#### 可选：恢复外网后切回公网授时

取消两台配置里 `pool ntp.ubuntu.com iburst` 的注释并 `systemctl restart chrony` 即可。公网源 stratum 2 低于本地 10/12，chrony 会自动优先公网源；`.28` 也可能直接同步公网而不是 .27，这属于正常行为。断网后会自动退回本地授时，无需人工干预。

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

### 3.5 一键部署（推荐，从控制机执行）

`scripts/deploy_cluster.sh` 在控制机（如 10.18.1.33）上运行，通过免密 SSH 完成第 3～9 节的全部动作：

```bash
cd /home/sder/ha/replica
./scripts/deploy_cluster.sh \
  --node1 10.18.1.27 --node2 10.18.1.28 --vip-list "10.18.1.30" \
  --fresh --yes
```

双 VIP 示例（整组同漂，第一个是数据面 VIP）：

```bash
./scripts/deploy_cluster.sh \
  --node1 10.18.1.27 --node2 10.18.1.28 \
  --vip-list "10.18.1.30,10.18.1.31/24" \
  --coremgr-port 8888 --nf-health-file /var/run/coremgr_nf_health \
  --fresh --yes
```

执行内容：同步仓库（不改节点数据）→ 逐台渲染 `docker-compose.yaml` / `base.sh` / keepalived → etcd 首次 bootstrap（`ETCD_CLUSTER_STATE=new` 仅通过命令环境传入，`.env` 始终保留 `existing`）→ 主库 MySQL/Redis → 主库 keepalived、VIP 组、etcdvip → 备库 MySQL 复制 → 备库 Redis → 备库 keepalived → 全量验收。

部署还会写 `/etc/keepalived/replica-vips`（一行一个 VIP，root:root 0644），作为 keepalived 与 coremgr 的**唯一 VIP 事实源**；验收会核对它与渲染出的 `virtual_ipaddress` 完全一致。compose 中 etcdvip 的 `VIP:23790/23800` 也按数据面 VIP 重写。

常用参数：

| 参数 | 说明 |
| --- | --- |
| `--node1/--node2/--iface` | 覆盖默认的 .27/.28/ens3 |
| `--vip IP` | 单个 VIP，等价于 `--vip-list` 只有一个元素（默认 `10.18.1.30`） |
| `--vip-list "IP[,IP...]"` | VIP 组，逗号分隔；第 1 个是数据面 VIP；可带 `/前缀`（缺省 `/24`） |
| `--coremgr-port N` | coremgr 端口，渲染进 `base.sh`，用于查询对端核心网健康（默认 8888） |
| `--nf-health-file P` | coremgr 写入的 verdict 文件路径（默认 `/var/run/coremgr_nf_health`） |
| `--master 10.18.1.28` | 指定初始主库（默认 node1） |
| `--fresh` | 允许清空两台的 `data/mysql`、`data/redis`、`data/etcd1`、`data/etcd2` |
| `--yes` | 非交互确认（配合 `--fresh`） |
| `--dry-run` | 只做只读预检并打印动作，不修改任何东西 |

安全边界：

- 只要任意一台检测到**非空数据目录、同名容器、运行中的 keepalived 或已存在的 VIP（组内任意一个）**，脚本会拒绝执行；必须显式 `--fresh` 才会清空。
- 非 `--fresh` 模式可安全重复执行：已有数据不会被删除。
- 首次 MySQL 初始化约 5 分钟（InnoDB + 时区数据），脚本让两台并行初始化，整体约 6～8 分钟。
- 失败时自动收集两台节点的容器日志、keepalived journal、wrapper log 到 `/tmp/replica-deploy-<时间戳>/`；退出码 0 成功 / 2 参数 / 3 预检拒绝 / 4 等待超时 / 5 校验失败。

手工分步执行仍然有效，对应关系：第 3 节 → 脚本 P3，第 4 节 → P5，第 5 节 → P6，第 6 节 → P7，第 7 节 → P8，第 8 节 → P10，第 9 节 → P11。

### 3.6 卸载/清理（从控制机执行）

`scripts/cleanup_cluster.sh` 清空两台节点上的集群状态，回到可以按本文档手工重新安装的干净状态：

```bash
cd /home/sder/ha/replica
./scripts/cleanup_cluster.sh \
  --node1 10.18.1.27 --node2 10.18.1.28 --vip-list "10.18.1.30" --yes
```

| 参数 | 说明 |
| --- | --- |
| `--node1/--node2/--iface` | 覆盖默认的 .27/.28/ens3 |
| `--vip IP` / `--vip-list L` | 与部署时一致，用于检查每个 VIP 是否还有残留；默认 `10.18.1.30` |
| `--yes` | 非交互确认；不加则要求输入 `DELETE` |
| `--dry-run` | 只检查 ssh/sudo/docker 连通性并打印动作，不修改任何东西 |

清理内容：

- **keepalived**：停止服务，删除 `/etc/keepalived/replica-runner.sh` 与 `/etc/keepalived/replica-vips`；`keepalived.conf` 从 `keepalived.conf.bak.*` 里恢复**部署前**的版本（跳过仍引用 `replica-runner` 的备份），没有可用备份则删除配置并 `disable keepalived`
- **容器**：`docker compose down --remove-orphans` + 强制删除 `mysql` / `redis` / `etcd` / `etcdvip`
- **数据**：`data/mysql`、`data/redis`、`data/etcd1`、`data/etcd2`
- **日志与运行态**：`logs/*.log`、`/var/run/replica_*`、`/tmp/master_dump*.sql`、`/tmp/keepalived.conf.new`

保留：仓库文件、docker 镜像、keepalived 软件包、ssh `known_hosts`、`keepalived.conf.bak.*`。清理完成后会逐台校验（无同名容器、无数据、无 VIP、keepalived 未运行、runner 已删除、端口空闲），有残留则退出码 5。退出码：0 成功 / 2 参数 / 3 取消或 ssh 预检失败 / 5 清理后校验失败 / 6 远程命令失败。

> 清理只针对 replica 集群。如果清理前 keepalived 上还跑着别的配置（例如 TiDB），脚本会尽量恢复部署前的 `keepalived.conf` 并用 `keepalived -t` 校验，但仍建议清理后用 `ip addr` 和 `systemctl status keepalived` 复核一次。

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

正确做法是放一个 root 拥有的转发脚本在 `/etc/keepalived` 下。仓库里已提供源文件 `scripts/replica-runner.sh`，两台都执行：

```bash
sudo install -o root -g root -m 755 \
    /home/sder/ha/replica/scripts/replica-runner.sh \
    /etc/keepalived/replica-runner.sh

# 校验：属主必须是 root，权限 755
ls -l /etc/keepalived/replica-runner.sh
```

> `replica-runner.sh` 只负责按参数转发：`check` → `check_mysql_status.sh`，`master` → `notify_master.sh`，`backup` → `notify_slave.sh`。以后修改任一脚本都不需要重装 runner，只有 runner 自身变更时才需要重新执行上面的 `install`。

`global_defs` 里的 `script_user root` 保证以 root 身份执行（脚本里有 `docker exec`、写 `/var/run`、`ip addr`，不能用 sder 跑）。

### 7.2 替换 keepalived 配置

TiDB 已永久下线，所以不再追加 `VI_TIDB`，而是**整份替换**成 replica 专用配置：

```bash
sudo cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak.$(date +%Y%m%d%H%M%S)
# .27 用 keepalived.conf，.28 用 keepalived.28.conf
sudo cp /home/sder/ha/replica/scripts/keepalived.conf /etc/keepalived/keepalived.conf   # .28: keepalived.28.conf
```

两份文件的差异：`priority`（.27=150 / .28=100）、`unicast_src_ip`、`unicast_peer`。VIP/peer 段落在模板里用
`# @@VIP_BEGIN@@ / @@VIP_END@@` 与 `# @@PEER_BEGIN@@ / @@PEER_END@@` 标记包起来，`deploy_cluster.sh` 按这两个标记
重写；手工部署时直接编辑标记之间的行即可（每个 VIP 一行，前缀缺省 `/24`）。

多 VIP 时 `virtual_ipaddress` 写多行，其余不变：

```
    virtual_ipaddress {
        # @@VIP_BEGIN@@
        10.18.1.30/24 dev ens3
        10.18.1.31/24 dev ens3
        # @@VIP_END@@
    }
```

同时写 VIP 事实源文件（coremgr 优先读它；两台的列表必须一致）：

```bash
printf '%s\n' 10.18.1.30/24 10.18.1.31/24 | sudo tee /etc/keepalived/replica-vips >/dev/null
sudo chown root:root /etc/keepalived/replica-vips && sudo chmod 644 /etc/keepalived/replica-vips
```

关键段落：

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

    virtual_ipaddress {
        # @@VIP_BEGIN@@
        10.18.1.30/24 dev ens3      # 多 VIP 直接加行，整组同漂
        # @@VIP_END@@
    }

    track_script { chk_mysql_ha }

    notify_master "/etc/keepalived/replica-runner.sh master"
    notify_backup "/etc/keepalived/replica-runner.sh backup"
    notify_fault  "/etc/keepalived/replica-runner.sh backup"
    notify_stop   "/etc/keepalived/replica-runner.sh backup"
}
```

> `track_script` 不配 `weight`：检查失败时实例直接进 FAULT、释放 VIP，备节点才能接管。
> `notify_fault` / `notify_stop` 是原仓库配置里缺失的，补上才能保证 keepalived 异常退出时 MySQL/Redis 被降级。
> 健康检查语义（`check_mysql_status.sh`）：**MASTER 侧** MySQL 不可用或 `read_only != 0` 才返回 1；MySQL 正常时还要通过核心网 gate（见 7.4），gate 要求切换时才返回 1，其余情况返回 0；**BACKUP 侧永远返回 0**，否则备节点会自己进 FAULT、无法接管。提升过程中靠 `/var/run/replica_promoting` 标记给出 120 秒宽限期，避免"先拿 VIP 后改 read_only"的时序误判。

### 7.3 校验并加载

```bash
# 语法检查（必须是 0；非 0 且报 "due to insecure" 说明还在用 /home 下的脚本）
sudo keepalived -t -f /etc/keepalived/keepalived.conf; echo "exit=$?"

# 单独跑一次健康检查，确认 runner 与脚本链路正常（BACKUP 侧返回 0 属正常）
sudo /etc/keepalived/replica-runner.sh check; echo "check-exit=$?"

# 单独看核心网 gate 与聚合状态（不改变 keepalived）
sudo /etc/keepalived/replica-runner.sh check-core status

# 配置已整份替换（无 VI_TIDB），直接启动
sudo systemctl start keepalived
```

`check-core status` 会打印本地 verdict 的关键字段、是否新鲜、以及当前会给出 exit 0 还是 1；`check-core gate`
只输出判定结果（0/1）并写告警，适合放进其他巡检脚本。

```bash
# 本机 verdict（coremgr 每 5 秒原子重写）
sudo cat /var/run/coremgr_nf_health

# 对端 verdict（coremgr 的 HTTP 视图，AllowNode）
curl -fsS --max-time 2 http://10.18.1.28:8888/coremgr/ha/health

# 本机 HA 汇总（VIP 持有、MySQL/Redis/etcd、核心网状态）
curl -fsS http://127.0.0.1:8888/coremgr/ha/status
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

### 7.4 核心网健康参与切换

5GC 的 NF（smf/nrf/ausf/udm/pcf/nssf）异常不再只靠人工发现，而是由 coremgr 聚合后交给 keepalived 判定。
keepalived **不直接探活 NF**，只看一个结论；这样探活逻辑、阈值、重启策略都在 coremgr 内演进，keepalived 配置保持稳定。

- coremgr 每 5 秒并发 `GET` 各 NF 的完整 URL，2xx 记为健康；连续 `fail_threshold` 次失败才置 `down`，
  连续 `rise_threshold` 次成功才恢复。配置在节点的
  `/usr/local/coremgr/config/cm_sys_conf.yaml` 的 `ha.nf_health`（仓库模板见 `oam/cm/data/cm_sys_conf.yaml`）。
- 级别：`critical`（默认 `nrf`、`smf`）故障会导致 `ready=0`，参与倒换；`important`（其余）故障只告警/尝试本地重启，
  不阻塞 `ready`。
- `enforce: false` 时 verdict 照常生成，但不参与切换（观察模式）；确认探活 URL 全部正确后再打开。
- `restart_enable: true` 时，`important` NF 连续故障会由 coremgr 通过容器管理接口原地重启，并受冷却时间、
  时间窗内次数上限约束；手动倒换进行中、处于提升宽限期、或正在执行 init/start/stop/upgrade/patch/rollback 时不会重启。
- 探活 URL 必须写真实路径：NRF 是 `/health_check`，不是 `/health`。用
  `curl -sS -o /dev/null -w '%{http_code}\n' <url>` 逐条确认后再打开 enforce。

判定语义（`check_core_status.sh`）：

| 场景 | MASTER 侧结果 |
|---|---|
| `enforce=0` | 0（观察模式，不影响切换） |
| verdict 缺失/过期/`poller≠up` | 0（未知不切，告警 `core_stale` / `core_missing`） |
| `ready=1` | 0 |
| `ready=0` 但 `critical_down=0`（仍在 grace/恢复中） | 0 |
| critical NF 确认故障且**对端 `ready=1`** | 1 → 释放 VIP，触发倒换 |
| critical NF 故障且**对端未就绪/不可达** | 0 → 保持现状，告警“暂不切换”，避免双方都不可用 |
| BACKUP 侧 | 永远 0（否则备机无法接管） |

MySQL 硬故障路径额外做对端检查：`CORE_PEER_GATE_MYSQL=1`（默认）时，若对端 verdict 明确未就绪则暂不切换；
对端端点不可用（例如旧版 coremgr 没有 `/coremgr/ha/health`）则按原 MySQL 故障逻辑切换并告警。

回滚/降噪：

- 只想关掉核心网参与切换：把 `nf_health.enforce` 置 `false` 并重启 coremgr，无需改 keepalived。
- 只想关掉自动重启：`restart_enable: false`。
- 调整阈值：`interval`、`fail_threshold`、`grace`、`stale_after`；`stale_after` 必须大于 `interval`。
- 升级 NF 前先置 `enforce: false` 可以避免滚动升级期间判为故障；升级完恢复。

---

## 8. 端到端验收清单

| # | 检查项 | 命令 | 期望 |
|---|---|---|---|
| 1 | VIP 组只在一台、整组齐全 | `ip -o -4 addr show ens3 \| grep -E '10\.18\.1\.(30\|31)'` | 仅 .27 同时有 .30/.31；.28 一个都没有 |
| 2 | MySQL 可写 | `mysql -h 10.18.1.30 -uroot -p's<9!Own1z4' -e "SELECT @@server_id, @@read_only"` | server_id=27，read_only=0 |
| 3 | 从库复制正常 | 在 .28 `SHOW SLAVE STATUS\G` | IO/SQL 均 Yes，延迟 0 |
| 4 | 从库只读 | 在 .28 `SELECT @@read_only, @@super_read_only` | 1 / 1 |
| 5 | Redis 主从 | 两台 `info replication` | master 1 个 slave；slave link up |
| 6 | etcd 健康 | `endpoint health` | 全部 healthy |
| 7 | etcd leader 唯一 | `endpoint status --write-out=table` | 恰好 1 个 true |
| 8 | etcdvip | 在主节点 `docker ps \| grep etcdvip`；`etcdctl --endpoints=http://10.18.1.30:23790 endpoint status` | 容器运行、端点可查 |
| 9 | 备节点无 etcdvip | 在 .28 `docker ps \| grep etcdvip` | 无输出 |
| 10 | 端口监听 | `sudo ss -lntp \| grep -E ':(3306\|6379\|2379\|2380\|23790\|23800\|8888)\b'` | 全部有进程 |
| 11 | 脚本日志 | `tail -50 /home/sder/ha/replica/logs/keepalived-wrapper.log` | 无 `command not found` / 无报错 |
| 12 | 已无 TiDB 实例 | `grep -c VI_TIDB /etc/keepalived/keepalived.conf` | 0 |
| 13 | 健康检查链路 | `sudo /etc/keepalived/replica-runner.sh check; echo $?` | 0 |
| 14 | 授时链路（见 2.5） | .27 `chronyc tracking`；.28 `chronyc sources -v` | .27 Stratum 10、本地时基；.28 `^* 10.18.1.27` |
| 15 | 两台时钟差 | `ssh 10.18.1.28 'date +%s.%N'; date +%s.%N` | 差 < 0.1s |
| 16 | VIP 事实源一致 | `cat /etc/keepalived/replica-vips`；对比 `keepalived.conf` 的 `virtual_ipaddress` | 两台内容一致，且与配置逐行对应 |
| 17 | verdict 新鲜 | `stat -c %Y /var/run/coremgr_nf_health`；`cat /var/run/coremgr_nf_health` | 时间在 20s 内，`poller=up` |
| 18 | 对端 health 可达 | `curl -fsS --max-time 2 http://10.18.1.28:8888/coremgr/ha/health` | 返回 key=value，`node` 为 .28 |
| 19 | 核心网结论 | `sudo /etc/keepalived/replica-runner.sh check-core status` | 全部 NF healthy，`ready=1`；MASTER 侧 gate=0 |
| 20 | NF 探活路径 | 对每个配置 URL 执行 `curl -sS -o /dev/null -w '%{http_code}'` | 200/2xx（NRF 用 `/health_check`） |

---

## 9. 切换演练

### 9.1 计划内切换（主 → 备）

```bash
# 1) 在持有 VIP 的节点（假定 .27）执行
sudo systemctl stop keepalived

# 2) 约 5~8 秒后在 .28 检查（整组 VIP 应一起出现，.27 上一个不剩）
ip -o -4 addr show ens3 | grep -E '10\.18\.1\.(30|31)'
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
ip -o -4 addr show ens3 | grep -E '10\.18\.1\.(30|31)'   # 整组仍然只在 .28
docker exec -i mysql mysql -uroot -p's<9!Own1z4' -e "SHOW SLAVE STATUS\G" | grep -E "Master_Host|Slave_IO_Running"
```

期望：.27 上 `Master_Host` 为 `10.18.1.30`（VIP），复制 Running。

### 9.3 非计划故障

- 节点级故障（关机 / 断网）会触发 VIP 漂移。
- 单组件故障：`check_mysql_status.sh` 已修正，MASTER 侧 `docker stop mysql` 会连续 3 次（`fall 3`，约 15 秒）检查失败 → 实例进 FAULT、释放 VIP → 备节点接管。BACKUP 侧 MySQL 或复制异常**不会**导致自身 FAIL（只告警 + 异步重建），这是刻意设计。
- 演练后如需重建备库：查看 `logs/keepalived-wrapper.log` 中的 `异步执行从库重建` 与 `=== 重建完成 ===`，或手工执行 `restore_mysql_slave.sh`。

核心网故障注入（`enforce: true` 前提下）：

| 操作 | 期望 |
|---|---|
| 在 MASTER 停 `core-nrf`（critical） | 约 10s verdict `ready=0`、`critical_down_names=nrf`；keepalived 连续 3 次 gate=1 后释放 VIP，约 25~30s 完成；交换机上 `ready=1` |
| 在 BACKUP 停一个 critical NF | BACKUP 的 `check` 仍 exit 0，keepalived 保持 BACKUP；不会主动抢 VIP |
| 停 `core-udm`（important） | `ready` 仍为 1，不切换；verdict `important_down=1`，告警 `nf_important_down` |
| 两台同时停 critical NF | MASTER gate 返回 0（对端也未就绪），VIP 不漂移，告警 `core_peer_block` |
| kill coremgr 或 verdict 变旧 | MASTER gate 返回 0，不切换；告警 `core_stale` |
| `enforce: false` 下停 critical NF | 不切换；`/coremgr/ha/status` 出现告警 |

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
| 8 | `docker-compose.yaml:112` | `ETCD_LEARNER` 非合法服务端参数，且 etcdvip 已在 `initial-cluster` | 可能启动失败 | ✅ `deploy_cluster.sh` 渲染时删除该行；手工部署按 4.1 删除 |
| 9 | `docker-compose.yaml:116-118` | etcdvip 没有数据卷 | `down` 后成员数据丢失 | 🔶 脚本改用 `compose stop`，数据保留；长期建议换 etcd-proxy |
| 10 | `check_mysql_status.sh` | 调 `mail` 但两台都没装 | 告警静默失败 | 🔶 已加 `command -v mail` 判断并限频写日志；建议装 mailutils 或改 webhook |
| 11 | `init.sh` | 编辑不存在的文件 + `set -e` | 直接失败 | ⬜ 不使用（见 3.4） |
| 12 | `restore_mysql_slave.sh` | IP/路径写死、无条件清空 `data/mysql` | 误用丢数据 | ✅ 源改 VIP；dump 为空即中止；持有 VIP 时拒绝执行；异步调用 |
| 13 | 全局 | 路径与密码硬编码 | 迁移/改密成本高 | 🔶 统一收敛到 `scripts/base.sh`；仍需改密时只改一处 |
| 14 | `config/redis.conf` | 挂载但被命令行参数覆盖 | 改文件无效 | ⬜ 删除挂载或改为单入口 |
| 15 | 授时 | 两台均依赖公网 `ntp.ubuntu.com`，内网无 NTP 服务器 | 断外网后各自自由运行，时钟逐渐漂移 | ✅ 2026-11-06 已切换为 chrony 内部主备（见 2.5）：.27 `local stratum 10` 授时，.28 同步 .27（实测 offset 微秒级） |
| 16 | `notify_slave.sh` 各子脚本 | keepalived 启动时先执行 BACKUP 过渡、再执行 MASTER 过渡，两者并行；降级的 Redis/etcd 子脚本可能在新主晋升**之后**才执行 | 新主 Redis 被 `SLAVEOF VIP` 降为从库、etcdvip 被停掉，主备不可用 | ✅ 2026-11-09：`mysql/redis/etcd_notify_slave.sh` 增加 `is_on_vip` 短路（已持 VIP 则跳过降级），MySQL 等待循环提前退出；`deploy_cluster.sh` 在过渡收尾后再强制一次主角色 |
| 17 | MySQL 首次初始化 | 本机磁盘上 InnoDB + 时区数据初始化约 5 分钟 | 部署等待超时 | ✅ 2026-11-09：`deploy_cluster.sh` 等待 600s，并让两台 MySQL 并行初始化 |
| 18 | `restore_mysql_slave.sh` | 用 `mysqladmin ping` 判断就绪，初始化阶段的临时实例会误报 | 导入过早失败 | ✅ 2026-11-09：改为 TCP + 密码 `SELECT 1`，最多等 300s |

### 10.1 核心网健康与多 VIP 排障

| 现象 | 排查 | 处理 |
|---|---|---|
| verdict 里某个 NF 一直是 `down`，但容器在运行 | `curl -v <该 NF 完整 URL>`；对照 `nf_health.nfs[].url` | 多半是路径写错（NRF 是 `/health_check`，其他常见 `/health`），改配置后重启 coremgr |
| verdict 不更新 / `updated` 很旧 | `systemctl status coremgr`；`ls -l /var/run/coremgr_nf_health`；coremgr 日志搜 `nf_health` | coremgr 未运行、`/var/run` 不可写（需 root）、或 `nf_health.enable=false` |
| 对端 `curl :8888/coremgr/ha/health` 失败 | 对端 coremgr 是否运行、`ss -lntp \| grep 8888`、两台防火墙 | 旧版 coremgr 没有该路由，先升级两端；端点不可达时 MySQL 故障仍按原逻辑切换 |
| NF 反复重启 | verdict `nf_<name>=restarting`；coremgr 日志 `restart`；看该 NF 容器日志 | 先修 NF 本身；临时置 `restart_enable: false` 止损；`restart_cooldown/window/max` 控制频率 |
| 滚动升级期间发生误切换 | `check-core status` 的 `critical_down_names` | 升级前置 `enforce: false`，升级完成并确认 `ready=1` 后恢复 |
| 只漂了部分 VIP | `ip -o -4 addr show ens3`；`cat /etc/keepalived/replica-vips`；`/coremgr/ha/status` 的 `vip_incomplete` 告警 | 两台的 `replica-vips` 必须一致；改完后 `keepalived -t` 并重启；不要在运行中手工 `ip addr add` |
| 想临时退回“只按 MySQL 切换” | — | `nf_health.enforce: false` + 重启 coremgr，无需回退二进制或 keepalived 配置 |
| 查看判定过程 | `sudo /etc/keepalived/replica-runner.sh check-core status`；`tail -f logs/keepalived-wrapper.log` | 告警 key：`core_critical`、`core_peer_block`、`core_stale`、`core_missing`，默认 300s 限频 |

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
ip -o -4 addr show ens3 | grep -E '10\.18\.1\.(30|31)'
cat /etc/keepalived/replica-vips
sudo systemctl status keepalived
sudo journalctl -u keepalived -f

# 核心网健康与 HA 状态
sudo /etc/keepalived/replica-runner.sh check-core status
cat /var/run/coremgr_nf_health
curl -fsS http://127.0.0.1:8888/coremgr/ha/status
curl -fsS http://10.18.1.28:8888/coremgr/ha/health   # 对端

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
| 节点 1 / 节点 2 / VIP 组 | 10.18.1.27 / 10.18.1.28 / 10.18.1.30（可多个，第一个为数据面） |
| NF 级别 / enforce / restart | 默认 nrf+smf critical，其余 important；enforce=false 观察，确认后开 true |
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
