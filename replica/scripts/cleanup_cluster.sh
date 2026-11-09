#!/bin/bash
# 一键卸载/清理 replica 主备集群（etcd + MySQL + Redis + keepalived）
#
# 在控制机（如 10.18.1.33）上运行，通过 ssh 清理两台节点：
#   ./cleanup_cluster.sh --node1 10.18.1.27 --node2 10.18.1.28 --yes
#
# 清理内容：
#   - keepalived：停止服务，删除 /etc/keepalived/replica-runner.sh；
#     keepalived.conf 恢复为部署前的备份（备份也引用 replica-runner 时忽略），无备份则删除
#   - 容器：mysql / redis / etcd / etcdvip（compose down + docker rm -f）
#   - 数据：data/mysql、data/redis、data/etcd1、data/etcd2
#   - 日志与运行态：logs/*.log、/var/run/replica_*、/tmp/master_dump*.sql、/tmp/keepalived.conf.new
#
# 保留：仓库本身、docker 镜像、keepalived 软件包、ssh known_hosts、keepalived.conf.bak.*
#
# 退出码：0 成功 / 2 参数 / 3 用户取消 / 5 清理后校验失败 / 6 远程命令失败

set -Eeuo pipefail

# ---------------- 默认值 ----------------
NODE1="10.18.1.27"
NODE2="10.18.1.28"
VIP="10.18.1.30"
IFACE="ens3"
ASSUME_YES=0
DRY_RUN=0

REPO="/home/sder/ha/replica"

RUN_ID=$(date +%Y%m%d-%H%M%S)
LOG_DIR="/tmp/replica-cleanup-$RUN_ID"
LOG_FILE="$LOG_DIR/cleanup.log"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new
          -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

# ---------------- 输出 ----------------
log()  { local m="[$(date '+%F %T')] $*"; printf '%s\n' "$m"; printf '%s\n' "$m" >>"$LOG_FILE"; }
warn() { log "WARN: $*"; }
die()  { local msg=$1 code=${2:-6}; log "ERROR: $msg"; exit "$code"; }

usage() {
    cat <<EOF
用法: $0 [选项]

  --node1 IP     节点 1（默认 $NODE1）
  --node2 IP     节点 2（默认 $NODE2）
  --vip IP       虚拟 IP（默认 $VIP）
  --iface NAME   网卡（默认 $IFACE）
  --yes          非交互确认（不询问）
  --dry-run      只检查连通性并打印将要执行的操作
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
            --yes)     ASSUME_YES=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "未知参数: $1" 2 ;;
        esac
    done

    [[ $NODE1 =~ ^[0-9.]+$ && $NODE2 =~ ^[0-9.]+$ && $VIP =~ ^[0-9.]+$ ]] \
        || die "--node1/--node2/--vip 必须是 IPv4 地址" 2
    [ "$NODE1" != "$NODE2" ] || die "node1 与 node2 不能相同" 2
}

# ---------------- 远程执行 ----------------
remote() {
    local h=$1; shift
    ssh "${SSH_OPTS[@]}" "sder@$h" "$@"
}

remote_q() {
    remote "$@" 2>/dev/null
}

remote_script() {
    local h=$1; shift
    local q="" a
    for a in "$@"; do q+=" '${a//\'/\'\\\'\'}'"; done
    ssh "${SSH_OPTS[@]}" "sder@$h" "bash -s --$q"
}

run_script() {
    local h=$1; shift
    if ((DRY_RUN)); then
        log "[dry-run] $h: 将执行清理脚本（参数: $*）"
        cat >/dev/null
        return 0
    fi
    log ">>> $h: 执行清理"
    remote_script "$h" "$@"
}

confirm() {
    if ((DRY_RUN)); then return 0; fi
    if ((ASSUME_YES)); then return 0; fi
    [ -t 0 ] || die "非交互环境请加 --yes" 3
    local ans
    read -r -p "将清空 $NODE1 / $NODE2 上的集群数据，输入 DELETE 继续: " ans
    [ "$ans" = "DELETE" ] || die "已取消" 3
}

preflight_node() {
    local h=$1
    ((DRY_RUN)) && log ">>> $h: 检查 ssh 连通性"
    remote_q "$h" true || die "$h: ssh 不可达（需要免密）" 3
    remote_q "$h" "sudo -n true" || die "$h: sudo -n 不可用" 3
    remote_q "$h" "docker info" >/dev/null 2>&1 || die "$h: docker 不可用" 3
}

# ---------------- 清理 ----------------
cleanup_node() {
    local h=$1
    run_script "$h" "$IFACE" "$VIP" "$REPO" <<'EOS'
set -uo pipefail
IFACE_=$1; VIP_=$2; REPO_=$3

echo "--- keepalived ---"
sudo -n systemctl stop keepalived 2>/dev/null || true
sudo -n pkill -f restore_mysql_slave.sh 2>/dev/null || true
sudo -n rm -f /etc/keepalived/replica-runner.sh

# 恢复部署前备份：跳过任何仍引用 replica-runner 的备份
restored=0
while IFS= read -r bak; do
    [ -n "$bak" ] || continue
    if ! sudo -n grep -q 'replica-runner' "$bak" 2>/dev/null; then
        sudo -n cp -a "$bak" /etc/keepalived/keepalived.conf
        echo "已恢复部署前配置: $bak"
        restored=1
        break
    fi
done < <(ls -1t /etc/keepalived/keepalived.conf.bak.* 2>/dev/null || true)

if [ "$restored" -eq 0 ]; then
    sudo -n rm -f /etc/keepalived/keepalived.conf
    sudo -n systemctl disable keepalived >/dev/null 2>&1 || true
    echo "未找到部署前配置，已删除 keepalived.conf 并 disable keepalived"
else
    if sudo -n keepalived -t -f /etc/keepalived/keepalived.conf >/dev/null 2>&1; then
        echo "恢复的 keepalived.conf 语法校验通过"
    else
        echo "WARN: 恢复的 keepalived.conf 语法校验未通过，请人工检查"
    fi
fi

echo "--- 容器 ---"
cd "$REPO_" 2>/dev/null || true
docker compose down --remove-orphans 2>/dev/null || true
for c in mysql redis etcd etcdvip; do
    docker rm -f "$c" >/dev/null 2>&1 || true
done

echo "--- 数据 ---"
sudo -n rm -rf "$REPO_/data/mysql" "$REPO_/data/redis" \
              "$REPO_/data/etcd1" "$REPO_/data/etcd2"
sudo -n install -d -o sder -g sder -m 775 "$REPO_/data"

echo "--- 日志与运行态 ---"
rm -f "$REPO_"/logs/*.log 2>/dev/null || true
sudo -n rm -f /var/run/replica_*
sudo -n rm -f /tmp/master_dump.sql /tmp/master_dump_local.sql /tmp/keepalived.conf.new

echo "--- 当前状态 ---"
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xE 'mysql|redis|etcd|etcdvip' || true
ip -o -4 addr show dev "$IFACE_" 2>/dev/null | grep "inet ${VIP_}/" || true
true
EOS
}

# ---------------- 清理后校验 ----------------
verify_node() {
    local h=$1 residue
    if ((DRY_RUN)); then log "[dry-run] 跳过 $h 校验"; return 0; fi
    residue=$(remote_script "$h" "$IFACE" "$VIP" "$REPO" <<'EOS'
set -uo pipefail
IFACE_=$1; VIP_=$2; REPO_=$3
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -xE 'mysql|redis|etcd|etcdvip' || true
sudo -n find "$REPO_/data" -mindepth 2 -print -quit 2>/dev/null || true
systemctl is-active keepalived 2>/dev/null | grep -qx active && echo "keepalived=active" || true
ip -o -4 addr show dev "$IFACE_" 2>/dev/null | grep "inet ${VIP_}/" || true
[ -e /etc/keepalived/replica-runner.sh ] && echo "残留 /etc/keepalived/replica-runner.sh" || true
ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(3306|6379|2379|2380|23790|23800)$' || true
true
EOS
)
    if [ -n "$residue" ]; then
        warn "$h 仍有残留:"
        printf '%s\n' "$residue" | sed 's/^/    /' | tee -a "$LOG_FILE" >&2
        return 1
    fi
    log "OK: $h 已清理干净"
    return 0
}

main() {
    mkdir -p "$LOG_DIR"
    parse_args "$@"

    log "清理 replica 集群：$NODE1 / $NODE2，VIP $VIP，网卡 $IFACE"
    log "日志: $LOG_FILE"
    if ((DRY_RUN)); then log "模式: dry-run（不修改任何东西）"; fi

    preflight_node "$NODE1"
    preflight_node "$NODE2"
    confirm

    cleanup_node "$NODE1"
    cleanup_node "$NODE2"

    local rc=0
    verify_node "$NODE1" || rc=1
    verify_node "$NODE2" || rc=1
    if ((rc != 0)); then
        die "清理后仍有残留，请查看上面的输出或 $LOG_FILE" 5
    fi

    log "完成。镜像与仓库保留，可按 DEPLOY.md 第 3～9 节手工重新安装。"
    if ((DRY_RUN)); then
        log "[dry-run] 实际未做任何修改"
    fi
}

main "$@"
