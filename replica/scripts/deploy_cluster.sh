#!/bin/bash
# 一键部署 replica 主备集群（etcd + MySQL + Redis + keepalived）
#
# 在控制机（如 10.18.1.33）上运行，通过 ssh 操作两台节点：
#   ./deploy_cluster.sh --node1 10.18.1.27 --node2 10.18.1.28 --fresh --yes
#
# 前置条件：
#   - 控制机可免密 ssh 到两台节点，节点上 sder 可直接 docker、sudo -n 可用
#   - 两台节点已存在 /home/sder/ha/replica 与所需镜像
#   - 两台之间已配置免密 ssh（从库重建脚本依赖）
#
# 退出码：0 成功 / 2 参数 / 3 预检拒绝 / 4 等待超时 / 5 校验失败 / 6 远程命令失败

set -Eeuo pipefail

# ---------------- 默认值 ----------------
NODE1="10.18.1.27"
NODE2="10.18.1.28"
VIP="10.18.1.30"
IFACE="ens3"
MASTER_ARG=""
FRESH=0
ASSUME_YES=0
DRY_RUN=0

REPO="/home/sder/ha/replica"
MYSQL_USER="root"
MYSQL_PASS='s<9!Own1z4'
REDIS_PASS='A8K5h7+6!?'
MYSQL_IMAGE="registry.cn-hangzhou.aliyuncs.com/10_18_1_2_5000/mysql:8.0"
REDIS_IMAGE="registry.cn-hangzhou.aliyuncs.com/10_18_1_2_5000/redis:6.0.9"
ETCD_IMAGE="registry.cn-hangzhou.aliyuncs.com/10_18_1_2_5000/etcd:latest"

RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/replica-deploy-$RUN_ID"
LOG_FILE="$LOG_DIR/deploy.log"
PHASE="init"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

# ---------------- 输出 ----------------
log()  { local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m"; printf '%s\n' "$m" >>"$LOG_FILE"; }
warn() { log "WARN: $*"; }
die()  { local msg=$1 code=${2:-6}; log "ERROR: $msg"; exit "$code"; }

redact() {
    local s="$*"
    s=${s//$MYSQL_PASS/******}
    s=${s//$REDIS_PASS/******}
    printf '%s' "$s"
}

phase() {
    PHASE="$1"
    log "================ $1 ================"
}

usage() {
    cat <<EOF
用法: $0 [选项]

  --node1 IP     节点 1（默认 $NODE1）
  --node2 IP     节点 2（默认 $NODE2）
  --vip IP       虚拟 IP（默认 $VIP）
  --iface NAME   网卡（默认 $IFACE）
  --master IP    初始主库节点，必须是 node1 或 node2（默认 node1）
  --fresh        允许清空已有数据/容器（默认检测到就拒绝）
  --yes          非交互确认（配合 --fresh）
  --dry-run      只做只读预检并打印将要执行的操作
  -h, --help     显示帮助
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --node1)   NODE1=${2:?}; shift 2 ;;
            --node2)   NODE2=${2:?}; shift 2 ;;
            --vip)     VIP=${2:?}; shift 2 ;;
            --iface)   IFACE=${2:?}; shift 2 ;;
            --master)  MASTER_ARG=${2:?}; shift 2 ;;
            --fresh)   FRESH=1; shift ;;
            --yes)     ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "未知参数: $1" 2 ;;
        esac
    done

    [[ $NODE1 =~ ^[0-9.]+$ && $NODE2 =~ ^[0-9.]+$ && $VIP =~ ^[0-9.]+$ ]] \
        || die "--node1/--node2/--vip 必须是 IPv4 地址" 2
    [ "$NODE1" != "$NODE2" ] || die "node1 与 node2 不能相同" 2

    if [ -z "$MASTER_ARG" ]; then
        MASTER_ARG=$NODE1
    fi
    case "$MASTER_ARG" in
        "$NODE1") MASTER_NODE=$NODE1; SLAVE_NODE=$NODE2 ;;
        "$NODE2") MASTER_NODE=$NODE2; SLAVE_NODE=$NODE1 ;;
        *) die "--master 必须是 $NODE1 或 $NODE2" 2 ;;
    esac
    MASTER_SID=$(awk -F. '{print $NF}' <<<"$MASTER_NODE")
    SLAVE_SID=$(awk -F. '{print $NF}' <<<"$SLAVE_NODE")
    INITIAL_CLUSTER="etcd1=http://$NODE1:2380,etcd2=http://$NODE2:2380,etcdvip=http://$VIP:23800"
}

# ---------------- 远程执行 ----------------
remote() {
    local h=$1; shift
    ssh "${SSH_OPTS[@]}" "sder@$h" "$@"
}

remote_q() {
    remote "$@" 2>/dev/null
}

# 远程执行一段脚本，脚本从 stdin 读取，参数通过 bash -s -- 传入
remote_script() {
    local h=$1; shift
    local q="" a
    for a in "$@"; do q+=" '${a//\'/\'\\\'\'}'"; done
    ssh "${SSH_OPTS[@]}" "sder@$h" "bash -s --$q"
}

run_remote() {
    local h=$1; shift
    local cmd="$*"
    log ">>> $h: $(redact "$cmd")"
    if ((DRY_RUN)); then return 0; fi
    remote "$h" "$cmd"
}

run_script() {
    local h=$1; shift
    if ((DRY_RUN)); then
        log "[dry-run] $h: 跳过远程脚本（参数: $*）"
        cat >/dev/null
        return 0
    fi
    log ">>> $h: 执行远程脚本（参数: $*）"
    remote_script "$h" "$@"
}

# ---------------- 等待 ----------------
wait_for() {
    local desc=$1 timeout=$2 interval=$3; shift 3
    if ((DRY_RUN)); then log "[dry-run] 将等待: $desc"; return 0; fi
    local start=$SECONDS
    until "$@"; do
        if (( SECONDS - start >= timeout )); then
            log "TIMEOUT(${timeout}s): $desc"
            return 1
        fi
        sleep "$interval"
    done
    log "OK($((SECONDS-start))s): $desc"
}

# ---------------- 预检 ----------------
preflight_local() {
    local t
    for t in ssh rsync jq awk sed grep timeout; do
        command -v "$t" >/dev/null || die "控制机缺少命令: $t" 2
    done
}

preflight_node() {
    local h=$1
    run_script "$h" <<'EOS' || return 1
set -euo pipefail
sudo -n true
docker info >/dev/null 2>&1
docker compose version >/dev/null 2>&1
[ -d /home/sder/ha/replica ] || { echo "缺少 /home/sder/ha/replica"; exit 1; }
command -v keepalived >/dev/null
command -v ssh >/dev/null
command -v ssh-keyscan >/dev/null
EOS
    # 镜像检查单独执行，便于报错
    remote "$h" "for img in '$MYSQL_IMAGE' '$REDIS_IMAGE' '$ETCD_IMAGE'; do
        docker image inspect \"\$img\" >/dev/null 2>&1 || { echo \"缺少镜像: \$img\"; exit 1; }
    done" || return 1
    # 本机 IP 必须在指定网卡上
    remote_q "$h" "ip -o -4 addr show dev '$IFACE'" | grep -q " $h/" \
        || { warn "$h: 网卡 $IFACE 上没有 $h"; return 1; }
    # 时间同步
    remote_q "$h" "chronyc tracking" | grep -q 'Leap status.*Normal' \
        || warn "$h: chrony 状态不是 Normal"
    return 0
}

# 返回 0 表示该节点已有状态（数据/容器/keepalived/VIP）
node_has_state() {
    local h=$1 out
    out=$(remote_q "$h" "
        sudo -n find $REPO/data -mindepth 2 -print -quit 2>/dev/null
        docker ps -a --format '{{.Names}}' | grep -xE 'mysql|redis|etcd|etcdvip' || true
        systemctl is-active keepalived 2>/dev/null | grep -qx active || true
        ip -o -4 addr show dev $IFACE 2>/dev/null | grep 'inet $VIP/' || true
    ") || true
    [ -n "$out" ]
}

node_port_conflicts() {
    local h=$1
    remote_q "$h" "ss -ltnH 2>/dev/null | awk '{print \$4}' | grep -E ':(3306|6379|2379|2380|23790|23800)\$'" \
        | sed "s/^/$h 端口占用: /" || true
    return 0
}

check_no_vip() {
    local h
    for h in "$NODE1" "$NODE2"; do
        if remote_q "$h" "ip -o -4 addr show dev $IFACE | grep -q 'inet $VIP/'"; then
            warn "$h 已持有 VIP $VIP"
            return 1
        fi
    done
    return 0
}

confirm_fresh() {
    if ((ASSUME_YES)); then return 0; fi
    [ -t 0 ] || die "--fresh 需要 --yes（非交互环境）" 2
    local ans
    read -r -p "将清空两台节点的 data/mysql、data/redis、data/etcd1、data/etcd2，输入 DELETE 继续: " ans
    [ "$ans" = "DELETE" ] || die "已取消" 3
}

# ---------------- 清理与目录 ----------------
fresh_cleanup() {
    local h=$1
    run_script "$h" <<'EOS'
set -uo pipefail
sudo -n systemctl stop keepalived 2>/dev/null || true
sudo -n pkill -f restore_mysql_slave.sh 2>/dev/null || true
cd /home/sder/ha/replica
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f mysql redis etcd etcdvip 2>/dev/null || true
rm -f /tmp/master_dump.sql /tmp/master_dump_local.sql
sudo -n rm -f /var/run/replica_*
sudo -n rm -rf /home/sder/ha/replica/data/mysql \
               /home/sder/ha/replica/data/redis \
               /home/sder/ha/replica/data/etcd1 \
               /home/sder/ha/replica/data/etcd2
sudo -n install -d -o sder -g sder -m 775 /home/sder/ha/replica/data
EOS
}

ensure_dirs() {
    local h=$1
    run_script "$h" <<'EOS'
set -euo pipefail
sudo -n install -d -o sder -g sder -m 775 /home/sder/ha/replica/logs
sudo -n chown sder:sder /home/sder/ha/replica/logs
sudo -n chmod 775 /home/sder/ha/replica/logs
mkdir -p /home/sder/ha/replica/data/{mysql,redis,etcd1,etcd2}
sudo -n chown sder:sder /home/sder/ha/replica/data \
    /home/sder/ha/replica/data/mysql /home/sder/ha/replica/data/redis \
    /home/sder/ha/replica/data/etcd1 /home/sder/ha/replica/data/etcd2
# wrapper 日志：sder 与 root 都能写（旧文件可能是 root:root 644，先删再建）
sudo -n rm -f /home/sder/ha/replica/logs/keepalived-wrapper.log \
               /home/sder/ha/replica/logs/redis.log
touch /home/sder/ha/replica/logs/keepalived-wrapper.log
sudo -n chown sder:sder /home/sder/ha/replica/logs/keepalived-wrapper.log
sudo -n chmod 664 /home/sder/ha/replica/logs/keepalived-wrapper.log
# Redis 若以非 root 运行，需要预先可写的日志文件
touch /home/sder/ha/replica/logs/redis.log
sudo -n chmod 666 /home/sder/ha/replica/logs/redis.log
EOS
}

# ---------------- 同步与渲染 ----------------
sync_repo() {
    local h=$1
    log ">>> rsync 仓库到 $h（排除 data/logs）"
    if ((DRY_RUN)); then
        log "[dry-run] 将执行 rsync -az $REPO/ sder@$h:$REPO/"
        return 0
    fi
    rsync -az \
        --exclude 'data/' --exclude 'logs/' --exclude '.git/' --exclude '*.log' \
        "$REPO/" "sder@$h:$REPO/"
}

render_compose() {
    local h=$1 ip=$2 name=$3 sid=$4
    run_script "$h" "$sid" "$name" "$ip" "$INITIAL_CLUSTER" <<'EOS'
set -euo pipefail
SID=$1; ETCD_NAME=$2; NODE_IP=$3; IC=$4
cd /home/sder/ha/replica

sed -E -i \
  -e "s#^([[:space:]]*- --server-id=)[0-9]+#\1${SID}#" \
  -e "s#^([[:space:]]*- ETCD_NAME=)etcd[0-9]+[[:space:]]*\$#\1${ETCD_NAME}#" \
  -e "s#^([[:space:]]*- ETCD_ADVERTISE_CLIENT_URLS=http://)[0-9.]+:2379[[:space:]]*\$#\1${NODE_IP}:2379#" \
  -e "s#^([[:space:]]*- ETCD_INITIAL_ADVERTISE_PEER_URLS=http://)[0-9.]+:2380[[:space:]]*\$#\1${NODE_IP}:2380#" \
  -e "s#^([[:space:]]*- ETCD_INITIAL_CLUSTER=).*\$#\1${IC}#" \
  -e "s#^([[:space:]]*- \./data/)etcd[0-9]+(:/etcd-data)[[:space:]]*\$#\1${ETCD_NAME}\2#" \
  -e "/^[[:space:]]*- ETCD_LEARNER=/d" \
  docker-compose.yaml

# .env 只保留 compose 实际使用的变量
sed -E -i 's/^#?[[:space:]]*ETCD_CLUSTER_STATE=.*/ETCD_CLUSTER_STATE=existing/' .env
grep -qx 'ETCD_CLUSTER_STATE=existing' .env

# 断言渲染结果
docker compose config > /tmp/dc-rendered.yml
grep -q -- "--server-id=${SID}" /tmp/dc-rendered.yml
grep -q "ETCD_NAME: ${ETCD_NAME}" /tmp/dc-rendered.yml
grep -q "ETCD_ADVERTISE_CLIENT_URLS: http://${NODE_IP}:2379" /tmp/dc-rendered.yml
grep -q "ETCD_INITIAL_ADVERTISE_PEER_URLS: http://${NODE_IP}:2380" /tmp/dc-rendered.yml
grep -q "ETCD_INITIAL_CLUSTER: ${IC}" /tmp/dc-rendered.yml
grep -q "source: /home/sder/ha/replica/data/${ETCD_NAME}" /tmp/dc-rendered.yml
! grep -q 'ETCD_LEARNER' /tmp/dc-rendered.yml
EOS
}

render_base() {
    local h=$1
    run_script "$h" "$IFACE" "$VIP" "$NODE1" "$NODE2" <<'EOS'
set -euo pipefail
IFACE_=$1; VIP_=$2; N1=$3; N2=$4
cd /home/sder/ha/replica
sed -E -i \
  -e "s#^IFACE=.*#IFACE=\"${IFACE_}\"#" \
  -e "s#^MYSQL_VIP=.*#MYSQL_VIP=\"${VIP_}\"#" \
  -e "s#^NODE1=.*#NODE1=\"${N1}\"#" \
  -e "s#^NODE2=.*#NODE2=\"${N2}\"#" \
  scripts/base.sh
sed -E -i "s#^MASTER_IP=.*#MASTER_IP=\"${VIP_}\"#" scripts/redis_notify_slave.sh
bash -n scripts/base.sh
EOS
}

render_keepalived() {
    local h=$1 ip=$2 peer=$3 prio=$4
    run_script "$h" "$ip" "$peer" "$prio" "$IFACE" "$VIP" <<'EOS'
set -euo pipefail
NODE_IP=$1; PEER_IP=$2; PRIO=$3; IFACE_=$4; VIP_=$5
cd /home/sder/ha/replica
src=scripts/keepalived.conf
[ -f "$src" ] || { echo "缺少 $src"; exit 1; }
sed -E \
  -e "s#^([[:space:]]*interface[[:space:]]+).*#\1${IFACE_}#" \
  -e "s#^([[:space:]]*priority[[:space:]]+)[0-9]+#\1${PRIO}#" \
  -e "s#^([[:space:]]*unicast_src_ip[[:space:]]+).*#\1${NODE_IP}#" \
  -e "s#^([[:space:]]+)10\.18\.1\.[0-9]+[[:space:]]*\$#\1${PEER_IP}#" \
  -e "s#^([[:space:]]+)10\.18\.1\.[0-9]+/24 dev .*#\1${VIP_}/24 dev ${IFACE_}#" \
  "$src" > /tmp/keepalived.conf.new
grep -q "priority $PRIO" /tmp/keepalived.conf.new
grep -q "unicast_src_ip $NODE_IP" /tmp/keepalived.conf.new
grep -q "virtual_router_id 251" /tmp/keepalived.conf.new
EOS
}

install_keepalived() {
    local h=$1
    run_script "$h" <<'EOS'
set -euo pipefail
cd /home/sder/ha/replica
sudo -n install -o root -g root -m 755 \
    scripts/replica-runner.sh /etc/keepalived/replica-runner.sh
sudo -n cp -a /etc/keepalived/keepalived.conf \
    "/etc/keepalived/keepalived.conf.bak.$(date +%Y%m%d%H%M%S)"
sudo -n install -o root -g root -m 644 \
    /tmp/keepalived.conf.new /etc/keepalived/keepalived.conf
[ "$(stat -c '%U:%G %a' /etc/keepalived/replica-runner.sh)" = "root:root 755" ]
sudo -n keepalived -t -f /etc/keepalived/keepalived.conf
sudo -n systemctl enable keepalived >/dev/null 2>&1 || true
EOS
}

setup_known_hosts() {
    local h=$1
    run_script "$h" "$VIP" <<'EOS'
set -euo pipefail
VIP_=$1
ssh-keyscan -H "$VIP_" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
ssh -o BatchMode=yes -o ConnectTimeout=5 "sder@$VIP_" true 2>/dev/null || true
EOS
}

# ---------------- 谓词 ----------------
# 用 TCP + 密码查询判断就绪：初始化阶段的临时实例 --skip-networking，不会误判
mysql_ready() {
    remote_q "$1" "docker exec -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -h 127.0.0.1 -uroot \
        -N -B -e 'SELECT 1'" | grep -qx 1
}

mysql_query() {
    local h=$1 sql=$2
    if ((DRY_RUN)); then return 0; fi
    printf '%s\n' "$sql" | remote "$h" \
        "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot -N -B"
}

mysql_master_ok() {
    local h=$1 sid=$2 out
    out=$(remote_q "$h" "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot -N -B \
        -e 'SELECT @@server_id, @@read_only, @@super_read_only, @@gtid_mode'") || return 1
    [ "$(awk '{print $1}' <<<"$out")" = "$sid" ] &&
    [ "$(awk '{print $2}' <<<"$out")" = "0" ] &&
    [ "$(awk '{print $3}' <<<"$out")" = "0" ] &&
    [ "$(awk '{print $4}' <<<"$out")" = "ON" ]
}

mysql_slave_readonly() {
    local out
    out=$(remote_q "$1" "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot -N -B \
        -e 'SELECT @@read_only, @@super_read_only'") || return 1
    [ "$(awk '{print $1}' <<<"$out")" = "1" ] && [ "$(awk '{print $2}' <<<"$out")" = "1" ]
}

replication_ok() {
    local h=$1 exp=$2 st
    st=$(remote_q "$h" "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot -e 'SHOW SLAVE STATUS\G'") || return 1
    grep -q 'Slave_IO_Running: Yes' <<<"$st" &&
    grep -q 'Slave_SQL_Running: Yes' <<<"$st" &&
    grep -q "Master_Host: $exp" <<<"$st" &&
    grep -q 'Auto_Position: 1' <<<"$st"
}

replication_error() {
    local h=$1
    remote_q "$h" "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot -e 'SHOW SLAVE STATUS\G'" \
        | grep -E 'Last_IO_Error:|Last_SQL_Error:' || true
}

redis_master_ok() {
    remote_q "$1" "docker exec -e REDISCLI_AUTH='$REDIS_PASS' redis redis-cli info replication" \
        | grep -q 'role:master'
}

redis_slave_ok() {
    local out
    out=$(remote_q "$1" "docker exec -e REDISCLI_AUTH='$REDIS_PASS' redis redis-cli info replication") || return 1
    grep -q 'role:slave' <<<"$out" &&
    grep -q "master_host:$2" <<<"$out" &&
    grep -q 'master_link_status:up' <<<"$out"
}

vip_on() {
    remote_q "$1" "ip -o -4 addr show dev $IFACE | grep -q 'inet $VIP/'"
}

vip_absent() {
    ! vip_on "$1"
}

keepalived_entered() {
    local h=$1 state=$2 since=$3
    remote_q "$h" "journalctl -u keepalived --since '$since' --no-pager 2>/dev/null" \
        | grep -q "Entering $state STATE"
}

keepalived_not_entered() {
    local h=$1 state=$2 since=$3
    ! remote_q "$h" "journalctl -u keepalived --since '$since' --no-pager 2>/dev/null" \
        | grep -q "Entering $state STATE"
}

notify_done() {
    local h=$1 role=$2 before=$3 seg
    seg=$(remote_q "$h" "tail -n +$((before+1)) $REPO/logs/keepalived-wrapper.log 2>/dev/null | \
        awk '/Starting ${role} transition/{f=1} f{print} /${role} transition completed/{if(f) exit}'") || return 1
    [ -n "$seg" ] || return 1
    grep -q "${role} transition completed" <<<"$seg" || return 1
    ! grep -qE 'script exit code: [1-9]' <<<"$seg"
}

# 只关心“过渡脚本是否已收尾”，不检查子脚本退出码（启动期的 BACKUP 过渡允许失败）
notify_completed() {
    local h=$1 role=$2 before=$3 seg
    seg=$(remote_q "$h" "tail -n +$((before+1)) $REPO/logs/keepalived-wrapper.log 2>/dev/null | \
        awk '/Starting ${role} transition/{f=1} f{print} /${role} transition completed/{if(f) exit}'") || return 1
    grep -q "${role} transition completed" <<<"$seg"
}

etcd_members_ok() {
    local out
    out=$(remote_q "$NODE1" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$NODE1:2379 member list -w json") || return 1
    jq -e '([.members[].name] | sort) == ["etcd1","etcd2","etcdvip"]' <<<"$out" >/dev/null
}

# bootstrap 阶段：etcdvip 尚未启动，只看 etcd1/etcd2 两个端点
etcd_bootstrap_ok() {
    local out
    out=$(remote_q "$NODE1" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$NODE1:2379,http://$NODE2:2379 endpoint status -w json") || return 1
    jq -e 'length == 2 and
           ([.[].Status.header.cluster_id] | unique | length == 1) and
           ([.[] | select(.Status.leader == .Status.header.member_id)] | length == 1)' \
        <<<"$out" >/dev/null || return 1
    etcd_members_ok
}

# 终态：三个端点都健康、同一个集群、唯一 leader、成员齐全
etcd_cluster_ok() {
    local out
    out=$(remote_q "$NODE1" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$NODE1:2379,http://$NODE2:2379,http://$VIP:23790 endpoint status -w json") \
        || return 1
    jq -e 'length == 3 and
           ([.[].Status.header.cluster_id] | unique | length == 1) and
           ([.[] | select(.Status.leader == .Status.header.member_id)] | length == 1)' \
        <<<"$out" >/dev/null || return 1
    etcd_members_ok
}

etcdvip_ok() {
    remote_q "$MASTER_NODE" "docker ps --format '{{.Names}}' | grep -qx etcdvip" || return 1
    remote_q "$MASTER_NODE" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$VIP:23790 endpoint health" | grep -q 'is healthy' || return 1
    local mid eid
    mid=$(remote_q "$MASTER_NODE" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$NODE1:2379 member list -w json" \
        | jq -r '.members[] | select(.name=="etcdvip") | .ID') || return 1
    eid=$(remote_q "$MASTER_NODE" "docker exec etcd etcdctl --command-timeout=5s \
        --endpoints=http://$VIP:23790 endpoint status -w json" \
        | jq -r '.[0].Status.header.member_id') || return 1
    [ -n "$mid" ] && [ "$mid" = "$eid" ]
}

# ---------------- 阶段 ----------------
phase_p1_preflight() {
    phase "P1 预检"
    preflight_local
    local h
    for h in "$NODE1" "$NODE2"; do
        log "检查节点 $h"
        preflight_node "$h" || die "$h 预检失败" 3
    done
    if ((!FRESH)); then
        check_no_vip || die "已存在 VIP，请先停止旧 keepalived" 3
        local conflicts
        conflicts=$(node_port_conflicts "$NODE1"; node_port_conflicts "$NODE2")
        [ -z "$conflicts" ] || { printf '%s\n' "$conflicts"; die "端口被占用" 3; }
    else
        log "跳过端口/VIP 预检（--fresh 会先清理本项目容器）"
    fi

    local has=0
    for h in "$NODE1" "$NODE2"; do
        if node_has_state "$h"; then has=1; warn "$h 存在数据/容器/keepalived/VIP"; fi
    done
    if ((has)); then
        ((FRESH)) || die "检测到已有状态；确认要重置请加 --fresh" 3
        confirm_fresh
    fi
}

phase_p2_prepare() {
    phase "P2 清理与目录准备"
    if ((FRESH)); then
        local h
        for h in "$NODE1" "$NODE2"; do fresh_cleanup "$h"; done
        local conflicts
        conflicts=$(node_port_conflicts "$NODE1"; node_port_conflicts "$NODE2")
        [ -z "$conflicts" ] || { printf '%s\n' "$conflicts"; die "清理后端口仍被非本项目进程占用" 3; }
        check_no_vip || die "清理后仍存在 VIP，请手工停止残留 keepalived" 3
    fi
    local h
    for h in "$NODE1" "$NODE2"; do
        ensure_dirs "$h" || die "$h 目录准备失败" 5
        setup_known_hosts "$h" || warn "$h known_hosts 预置失败"
    done
}

phase_p3_sync_render() {
    phase "P3 同步代码与节点渲染"
    local h ip sid name
    for h in "$NODE1" "$NODE2"; do
        sync_repo "$h"
        if [ "$h" = "$NODE1" ]; then
            ip=$NODE1; sid=$MASTER_SID; name=etcd1
        else
            ip=$NODE2; sid=$SLAVE_SID; name=etcd2
        fi
        render_compose "$h" "$ip" "$name" "$sid" || die "$h compose 渲染/断言失败" 5
        render_base "$h" || die "$h base.sh 渲染失败" 5
        local peer prio
        if [ "$h" = "$NODE1" ]; then peer=$NODE2; else peer=$NODE1; fi
        if [ "$h" = "$MASTER_NODE" ]; then prio=150; else prio=100; fi
        render_keepalived "$h" "$ip" "$peer" "$prio" \
            || die "$h keepalived 渲染失败" 5
        install_keepalived "$h" || die "$h keepalived 安装/语法检查失败" 5
    done
    if ((DRY_RUN)); then return 0; fi
    # MySQL 尚未启动，此时 runner check 在 BACKUP 分支返回 0，不会触发重建
    remote "$NODE1" "sudo -n /etc/keepalived/replica-runner.sh check" \
        || warn "$NODE1 runner check 非 0（MySQL 尚未启动，可忽略）"
    remote "$NODE2" "sudo -n /etc/keepalived/replica-runner.sh check" \
        || warn "$NODE2 runner check 非 0（MySQL 尚未启动，可忽略）"
}

phase_p5_etcd() {
    phase "P5 etcd bootstrap"
    local h
    for h in "$NODE1" "$NODE2"; do
        run_remote "$h" "cd $REPO && env ETCD_CLUSTER_STATE=new docker compose up -d etcd"
    done
    wait_for "etcd 2/2 healthy、唯一 leader、3 个成员" 90 2 etcd_bootstrap_ok \
        || die "etcd bootstrap 超时（查看 docker compose logs etcd）" 4
    log "etcd 集群已建立"
}

phase_p6_master_services() {
    phase "P6 主库节点 MySQL/Redis：$MASTER_NODE"
    run_remote "$MASTER_NODE" "cd $REPO && docker compose up -d mysql redis"
    # 首次初始化约 5 分钟，备库提前并行初始化，缩短整体时间
    run_remote "$SLAVE_NODE" "cd $REPO && docker compose up -d mysql"
    wait_for "主库 MySQL 就绪（TCP+鉴权）" 600 3 mysql_ready "$MASTER_NODE" || die "主库 MySQL 未就绪" 5
    wait_for "MySQL 可写（server_id=$MASTER_SID, read_only=0, GTID=ON）" 120 1 \
        mysql_master_ok "$MASTER_NODE" "$MASTER_SID" || die "主库 MySQL 状态不正确" 5
    wait_for "Redis PONG 且 role:master" 60 2 redis_master_ok "$MASTER_NODE" \
        || die "主库 Redis 未就绪" 5
}

# keepalived 启动时会先执行 BACKUP 过渡、再执行 MASTER 过渡，两个过渡的子脚本并行；
# 即使降级脚本加了 is_on_vip 保护，也再等它们全部收尾并把主角色强制一次。
reconcile_master() {
    local before=$1
    wait_for "启动期 BACKUP 过渡收尾" 120 2 notify_completed "$MASTER_NODE" BACKUP "$before" \
        || warn "BACKUP 过渡未在 120s 内收尾，继续强制主角色"
    if ((DRY_RUN)); then return 0; fi

    log ">>> $MASTER_NODE: 重新强制主角色（MySQL/Redis/etcdvip）"
    printf '%s\n' "STOP SLAVE; RESET SLAVE ALL;
SET GLOBAL read_only=OFF; SET GLOBAL super_read_only=OFF; FLUSH BINARY LOGS;" \
        | remote "$MASTER_NODE" "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot"
    remote "$MASTER_NODE" "docker exec -e REDISCLI_AUTH='$REDIS_PASS' redis redis-cli SLAVEOF NO ONE" >/dev/null
    remote "$MASTER_NODE" "cd $REPO && docker compose up -d etcdvip" >/dev/null

    wait_for "MySQL 可写主库" 30 1 mysql_master_ok "$MASTER_NODE" "$MASTER_SID" \
        || die "重断言后主库 MySQL 状态异常" 5
    wait_for "Redis 主角色" 30 1 redis_master_ok "$MASTER_NODE" \
        || die "重断言后 Redis 角色异常" 5
    wait_for "etcdvip 在 $VIP:23790 健康" 150 3 etcdvip_ok \
        || die "etcdvip 未加入集群（查看 docker logs etcdvip）" 5
}

phase_p7_master_keepalived() {
    phase "P7 主库节点 keepalived、VIP、etcdvip"
    local before mark
    before=$(remote_q "$MASTER_NODE" "wc -l < $REPO/logs/keepalived-wrapper.log 2>/dev/null || echo 0")
    mark=$(remote_q "$MASTER_NODE" "date '+%F %T'")
    run_remote "$MASTER_NODE" "sudo -n systemctl restart keepalived"
    wait_for "VIP $VIP 在主库 $MASTER_NODE" 60 1 vip_on "$MASTER_NODE" \
        || die "主库未拿到 VIP（检查 keepalived 健康检查是否失败）" 4
    wait_for "keepalived 进入 MASTER" 60 1 keepalived_entered "$MASTER_NODE" MASTER "$mark" \
        || die "keepalived 未进入 MASTER" 4
    wait_for "notify_master 全部成功" 180 2 notify_done "$MASTER_NODE" MASTER "$before" \
        || die "notify_master 有子脚本失败" 5
    reconcile_master "$before"
}

phase_p8_slave_mysql() {
    phase "P8 备库 $SLAVE_NODE 接入复制"
    run_remote "$SLAVE_NODE" "cd $REPO && docker compose up -d mysql"
    wait_for "备库 MySQL 就绪（TCP+鉴权）" 600 3 mysql_ready "$SLAVE_NODE" || die "备库 MySQL 未就绪" 5

    # 连通性：备库容器直连主库 3306
    run_remote "$SLAVE_NODE" "docker exec -e MYSQL_PWD='$MYSQL_PASS' mysql \
        mysql -h $MASTER_NODE -uroot -N -B -e 'SELECT @@server_id'" >/dev/null \
        || die "备库无法连接主库 $MASTER_NODE:3306" 5

    # 预判 GTID 断档
    local mp se
    mp=$(mysql_query "$MASTER_NODE" "SELECT @@global.gtid_purged" || true)
    se=$(mysql_query "$SLAVE_NODE" "SELECT @@global.gtid_executed" || true)
    if [ -n "$mp" ] && [ -z "$se" ]; then
        warn "主库 gtid_purged 非空而备库 gtid_executed 为空，直接走重建"
        fallback_restore
        return 0
    fi

    setup_replication_direct
    if ! wait_for "复制 IO/SQL 正常（直连主库）" 90 2 \
            replication_ok "$SLAVE_NODE" "$MASTER_NODE"; then
        local err
        err=$(replication_error "$SLAVE_NODE")
        log "复制错误: $(redact "$err")"
        if grep -qiE '1236|purged|GTID|1837|Duplicate entry' <<<"$err"; then
            warn "GTID/历史不一致，改用全量重建"
            fallback_restore
        else
            die "复制建立失败（非 GTID 类错误，不自动重建）" 5
        fi
    fi

    wait_for "备库只读（read_only=1, super_read_only=1）" 30 2 \
        mysql_slave_readonly "$SLAVE_NODE" || die "备库未设置为只读" 5
}

setup_replication_direct() {
    local sql
    sql="SET GLOBAL super_read_only=OFF;
SET GLOBAL read_only=OFF;
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
  MASTER_HOST='$MASTER_NODE',
  MASTER_USER='$MYSQL_USER',
  MASTER_PASSWORD='$MYSQL_PASS',
  MASTER_PORT=3306,
  MASTER_AUTO_POSITION=1,
  MASTER_CONNECT_RETRY=10;
START SLAVE;
SET GLOBAL read_only=ON;
SET GLOBAL super_read_only=ON;"
    log ">>> $SLAVE_NODE: 配置复制指向 $MASTER_NODE（SQL 已脱敏）"
    if ((DRY_RUN)); then return 0; fi
    printf '%s\n' "$sql" | remote "$SLAVE_NODE" \
        "docker exec -i -e MYSQL_PWD='$MYSQL_PASS' mysql mysql -uroot"
}

fallback_restore() {
    phase "P8b 全量重建备库"
    wait_for "VIP 在主库（重建依赖）" 60 1 vip_on "$MASTER_NODE" \
        || die "重建前 VIP 不在主库" 5
    if ! remote_q "$SLAVE_NODE" "ssh -o BatchMode=yes -o ConnectTimeout=5 sder@$VIP true"; then
        warn "备库无法免密 ssh 到 VIP，尝试补 known_hosts"
        setup_known_hosts "$SLAVE_NODE"
        remote_q "$SLAVE_NODE" "ssh -o BatchMode=yes -o ConnectTimeout=5 sder@$VIP true" \
            || die "备库无法 ssh 到 VIP，无法执行重建" 5
    fi
    log ">>> 停止备库 MySQL 并将数据/日志目录交给 sder（restore 需要）"
    if ((!DRY_RUN)); then
        remote "$SLAVE_NODE" "docker stop mysql 2>/dev/null || true"
        remote "$SLAVE_NODE" "sudo -n chown -R sder:sder $REPO/data/mysql $REPO/logs"
    fi
    run_remote "$SLAVE_NODE" "timeout 1800 $REPO/scripts/restore_mysql_slave.sh"
    wait_for "重建后复制指向 VIP" 120 3 replication_ok "$SLAVE_NODE" "$VIP" \
        || die "重建后复制仍不正常" 5
    wait_for "重建后备库只读" 30 2 mysql_slave_readonly "$SLAVE_NODE" \
        || die "重建后备库未只读" 5
}

phase_p9_slave_redis() {
    phase "P9 备库 Redis"
    run_remote "$SLAVE_NODE" "cd $REPO && docker compose up -d redis"
    wait_for "备库 Redis PONG" 60 2 redis_ping "$SLAVE_NODE" || die "备库 Redis 未就绪" 5
    run_remote "$SLAVE_NODE" "docker exec -e REDISCLI_AUTH='$REDIS_PASS' redis \
        redis-cli SLAVEOF $MASTER_NODE 6379"
    wait_for "备库 Redis 同步主库" 60 2 redis_slave_ok "$SLAVE_NODE" "$MASTER_NODE" \
        || die "备库 Redis 复制未建立" 5
}

redis_ping() {
    remote_q "$1" "docker exec -e REDISCLI_AUTH='$REDIS_PASS' redis redis-cli ping" \
        | grep -q PONG
}

phase_p10_slave_keepalived() {
    phase "P10 备库 keepalived"
    local before mark
    before=$(remote_q "$SLAVE_NODE" "wc -l < $REPO/logs/keepalived-wrapper.log 2>/dev/null || echo 0")
    mark=$(remote_q "$SLAVE_NODE" "date '+%F %T'")
    run_remote "$SLAVE_NODE" "sudo -n systemctl restart keepalived"
    wait_for "备库不持有 VIP" 60 1 vip_absent "$SLAVE_NODE" || die "备库抢到了 VIP" 5
    wait_for "keepalived 进入 BACKUP" 60 1 keepalived_entered "$SLAVE_NODE" BACKUP "$mark" \
        || die "备库未进入 BACKUP" 4
    wait_for "notify_backup 全部成功" 150 2 notify_done "$SLAVE_NODE" BACKUP "$before" \
        || die "notify_backup 有子脚本失败" 5
    wait_for "复制源已切换为 VIP" 90 2 replication_ok "$SLAVE_NODE" "$VIP" \
        || die "notify_backup 后复制未指向 VIP" 5
    wait_for "Redis 已指向 VIP" 60 2 redis_slave_ok "$SLAVE_NODE" "$VIP" \
        || die "notify_backup 后 Redis 未指向 VIP" 5
    if remote_q "$SLAVE_NODE" "pgrep -f restore_mysql_slave.sh"; then
        warn "备库有误调度的 restore 进程，清理"
        if ((!DRY_RUN)); then
            remote "$SLAVE_NODE" "sudo -n pkill -f restore_mysql_slave.sh || true"
        fi
    fi
}

verify_acceptance() {
    phase "P11 验收"
    local fail=0
    vip_on "$MASTER_NODE" && log "OK  VIP 在 $MASTER_NODE" || { warn "VIP 不在 $MASTER_NODE"; fail=1; }
    vip_absent "$SLAVE_NODE" && log "OK  备库无 VIP" || { warn "备库有 VIP"; fail=1; }
    if ((DRY_RUN)); then log "[dry-run] 跳过服务状态验收"; return 0; fi

    mysql_master_ok "$MASTER_NODE" "$MASTER_SID" && log "OK  主库可写" \
        || { warn "主库不可写"; fail=1; }
    mysql_slave_readonly "$SLAVE_NODE" && log "OK  备库只读" \
        || { warn "备库不是只读"; fail=1; }
    replication_ok "$SLAVE_NODE" "$VIP" && log "OK  复制指向 VIP" \
        || { warn "复制状态异常"; fail=1; }
    redis_master_ok "$MASTER_NODE" && log "OK  Redis 主" \
        || { warn "Redis 角色异常"; fail=1; }
    redis_slave_ok "$SLAVE_NODE" "$VIP" && log "OK  Redis 从" \
        || { warn "Redis 从库异常"; fail=1; }
    etcd_cluster_ok && log "OK  etcd 3/3 + leader + 3 成员" \
        || { warn "etcd 状态异常"; fail=1; }
    etcdvip_ok && log "OK  etcdvip 健康" || { warn "etcdvip 异常"; fail=1; }

    local h
    for h in "$MASTER_NODE" "$SLAVE_NODE"; do
        remote_q "$h" "sudo -n /etc/keepalived/replica-runner.sh check" \
            && log "OK  $h runner check" || { warn "$h runner check 失败"; fail=1; }
    done

    remote_q "$MASTER_NODE" "ss -ltnH | awk '{print \$4}' | grep -qE ':(3306|6379|2379|2380|23790|23800)\$'" \
        && log "OK  主库端口监听正常" || { warn "主库端口不全"; fail=1; }

    return "$fail"
}

collect_diagnostics() {
    if ((DRY_RUN)); then return 0; fi
    log "收集诊断信息到 $LOG_DIR"
    local h
    for h in "$NODE1" "$NODE2"; do
        {
            echo "===== $h ====="
            ssh "${SSH_OPTS[@]}" "sder@$h" "
                date
                systemctl is-active keepalived || true
                ip -o -4 addr show dev $IFACE || true
                ss -ltnH || true
                docker ps -a || true
                for c in mysql redis etcd etcdvip; do
                  echo \"--- docker logs \$c ---\"
                  docker logs --tail 100 \"\$c\" 2>&1 || true
                done
                echo '--- keepalived journal ---'
                sudo -n journalctl -u keepalived -n 150 --no-pager 2>&1 || true
                echo '--- wrapper log ---'
                tail -n 150 $REPO/logs/keepalived-wrapper.log 2>&1 || true
                echo '--- redis log ---'
                tail -n 100 $REPO/logs/redis.log 2>&1 || true
            " 2>&1 || true
        } >> "$LOG_DIR/diag-$h.log"
    done
}

on_exit() {
    local rc=$?
    trap - EXIT
    if ((rc != 0)); then
        collect_diagnostics || true
    fi
    exit "$rc"
}

main() {
    parse_args "$@"
    mkdir -p "$LOG_DIR"
    trap on_exit EXIT

    log "部署目标: node1=$NODE1 node2=$NODE2 vip=$VIP master=$MASTER_NODE"
    if ((FRESH)); then log "模式: --fresh（会清空两台 data 目录）"; fi
    if ((DRY_RUN)); then log "模式: --dry-run（只读）"; fi

    phase_p1_preflight
    phase_p2_prepare
    phase_p3_sync_render
    phase_p5_etcd
    phase_p6_master_services
    phase_p7_master_keepalived
    phase_p8_slave_mysql
    phase_p9_slave_redis
    phase_p10_slave_keepalived

    if ! verify_acceptance; then
        die "验收未通过，见 $LOG_DIR" 5
    fi
    log "部署完成。日志: $LOG_DIR"
    log "重装命令: $0 --node1 $NODE1 --node2 $NODE2 --vip $VIP --fresh --yes"
}

main "$@"
