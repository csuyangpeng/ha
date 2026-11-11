#!/usr/bin/env bash
# replica 集群巡检（从控制机 10.18.1.33 远程探测 .27 / .28）
#
# 检查内容：SSH/ICMP 可达、启动时间、keepalived 与 VIP 归属、容器健康、
#           MySQL 主从角色与复制状态、Redis 主从、etcd 端点、chrony 时间同步、
#           VIP 上的服务路径（3306 / 6379 / 23790）。
#
# 退出码：0=全部正常；1=有 WARN；2=有 FAIL。
#
# 用法：
#   ./check_cluster_status.sh
#   ./check_cluster_status.sh --node1 10.18.1.27 --node2 10.18.1.28 --vip 10.18.1.30
#   ./check_cluster_status.sh --vip-list "10.18.1.30,10.18.1.31/24"
#   ./check_cluster_status.sh -q          # 只输出异常项和汇总
#
# 也可以放到 cron / 监控里：退出码非 0 即需要人看。

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 复用 repo 里的节点/凭据定义；单独拷走本脚本时使用下面的默认值。
if [ -f "$SCRIPT_DIR/base.sh" ]; then
    # shellcheck source=base.sh
    . "$SCRIPT_DIR/base.sh"
fi

NODE1=${NODE1:-10.18.1.27}
NODE2=${NODE2:-10.18.1.28}
# base.sh 已定义 VIPS/MYSQL_VIP；单独拷走本脚本时用下面的默认值
VIPS=("${VIPS[@]:-10.18.1.30}")
MYSQL_VIP=${MYSQL_VIP:-${VIPS[0]%%/*}}
MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASS=${MYSQL_PASS:-'s<9!Own1z4'}
REDIS_PASS=${REDIS_PASS:-'A8K5h7+6!?'}
IFACE=${IFACE:-ens3}
SSH_USER=${SSH_USER:-sder}
SSH_TMO=${SSH_TMO:-8}

QUIET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --node1)  NODE1=$2; shift 2 ;;
        --node2)  NODE2=$2; shift 2 ;;
        --vip)    MYSQL_VIP=$2; shift 2 ;;
        --vip-list)
                  IFS=',' read -r -a VIPS <<<"$2"; shift 2
                  MYSQL_VIP=${VIPS[0]%%/*} ;;
        --user)   SSH_USER=$2; shift 2 ;;
        --timeout) SSH_TMO=$2; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $1（-h 查看用法）" >&2; exit 2 ;;
    esac
done

VIPS_LIST=$(printf '%s,' "${VIPS[@]}"); VIPS_LIST=${VIPS_LIST%,}

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no)

if [ -t 1 ]; then
    C_RST=$'\e[0m'; C_HDR=$'\e[1;36m'; C_OK=$'\e[32m'
    C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_INFO=$'\e[90m'
else
    C_RST=; C_HDR=; C_OK=; C_WARN=; C_FAIL=; C_INFO=
fi

OK=0; WARN=0; FAIL=0
WARN_MSGS=(); FAIL_MSGS=()
HOLDER=""

section() { [ "$QUIET" = 1 ] || printf '\n%s== %s ==%s\n' "$C_HDR" "$*" "$C_RST"; }
ok()   { OK=$((OK+1));   [ "$QUIET" = 1 ] || printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_RST" "$*"; }
warn() { WARN=$((WARN+1)); WARN_MSGS+=("$*"); printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_RST" "$*"; }
fail() { FAIL=$((FAIL+1)); FAIL_MSGS+=("$*"); printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_RST" "$*"; }
info() { [ "$QUIET" = 1 ] || printf '  %s[info]%s %s\n' "$C_INFO" "$C_RST" "$*"; }

ssh_run() {  # ssh_run <ip> <cmd...>
    local ip=$1; shift
    timeout "$SSH_TMO" ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "$@" 2>/dev/null
}

vip_regex() {
    local v out=""
    for v in "${VIPS[@]}"; do
        v=${v%%/*}
        out+="${out:+|}${v//./\\.}"
    done
    echo "$out"
}

held_vips() {  # 节点当前持有的、属于配置列表的 VIP
    ssh_run "$1" "ip -o -4 addr show dev $IFACE | grep -oE 'inet ($(vip_regex))/' | awk '{print \$2}' | cut -d/ -f1 | paste -sd, -"
}

kv_get() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

remote_mysql() {  # remote_mysql <ip> <sql>  -> 制表符分隔、无表头
    local ip=$1 sql=$2
    ssh_run "$ip" "docker exec mysql mysql -u'$MYSQL_USER' -p'$MYSQL_PASS' -N -B -e \"$sql\""
}

remote_mysql_vertical() {  # remote_mysql_vertical <ip> <sql>  -> 竖排 key: value
    local ip=$1 sql=$2
    ssh_run "$ip" "docker exec mysql mysql -u'$MYSQL_USER' -p'$MYSQL_PASS' -e \"$sql\""
}

# ---------------------------------------------------------------- 节点基础
NODE_HOLDER=0
check_node() {
    local ip=$1 name=$2
    NODE_HOLDER=0
    section "$name ($ip)"
    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        ok "ICMP 可达"
    else
        fail "ICMP 不可达"
        return 1
    fi
    if ssh_run "$ip" true; then
        ok "SSH 可达"
    else
        fail "SSH 不可达（免密或网络问题）"
        return 1
    fi
    local boot up
    boot=$(ssh_run "$ip" 'uptime -s')
    up=$(ssh_run "$ip" 'uptime -p')
    info "启动时间 ${boot:-未知}（${up:-未知}）"

    local st
    st=$(ssh_run "$ip" 'systemctl is-active keepalived')
    [ "$st" = "active" ] && ok "keepalived active" || fail "keepalived 状态：${st:-未知}"

    local held total
    total=${#VIPS[@]}
    held=$(held_vips "$ip")
    IFS=',' read -r -a held_arr <<<"$held"
    [ -n "$held" ] || held_arr=()

    if [ "${#held_arr[@]}" -eq "$total" ]; then
        info "持有全部 VIP（${held}）"
        NODE_HOLDER=1
    elif [ "${#held_arr[@]}" -gt 0 ]; then
        fail "仅持有 ${#held_arr[@]}/${total} 个 VIP（${held}），整组应同漂"
    else
        info "未持有 VIP"
    fi
    return 0
}

# 核心网 NF 健康（coremgr 写入的 verdict 文件）
check_core_health() {
    local ip=$1 out updated stale now age ready state cd names
    out=$(ssh_run "$ip" "cat /var/run/coremgr_nf_health 2>/dev/null")
    if [ -z "$out" ]; then
        warn "核心网健康文件不存在（coremgr 未运行、未启用 nf_health 或为旧版本）"
        return
    fi
    updated=$(printf '%s\n' "$out" | kv_get updated)
    stale=$(printf '%s\n' "$out" | kv_get stale_after)
    ready=$(printf '%s\n' "$out" | kv_get ready)
    state=$(printf '%s\n' "$out" | kv_get state)
    cd=$(printf '%s\n' "$out" | kv_get critical_down)
    names=$(printf '%s\n' "$out" | kv_get critical_down_names)
    now=$(date +%s)
    age=$(( now - ${updated:-0} ))

    if [ "${updated:-0}" -le 0 ] || [ "$age" -gt $(( ${stale:-20} + 5 )) ]; then
        warn "核心网健康数据已过期（${age}s 未更新）"
        return
    fi
    if [ "$ready" = "1" ]; then
        ok "核心网就绪（state=${state}）"
    elif [ "${cd:-0}" -gt 0 ]; then
        fail "核心网关键网元异常：${names:-${state}}"
    else
        warn "核心网未就绪（state=${state}，尚未确认故障）"
    fi
}

# ---------------------------------------------------------------- 容器
check_containers() {
    local ip=$1 holder=$2
    local want=(mysql redis etcd)
    [ "$holder" = 1 ] && want+=(etcdvip)

    local out
    out=$(ssh_run "$ip" "docker ps --format '{{.Names}}|{{.Status}}'")
    if [ -z "$out" ]; then
        fail "docker ps 无输出（docker 未运行？）"
        return
    fi

    local c line status
    for c in "${want[@]}"; do
        line=$(printf '%s\n' "$out" | awk -F'|' -v c="$c" '$1==c')
        if [ -z "$line" ]; then
            fail "容器 $c 未运行"
            continue
        fi
        status=${line#*|}
        case "$status" in
            *unhealthy*) fail "容器 $c unhealthy：$status" ;;
            *healthy*)   ok   "容器 $c healthy" ;;
            Up*)         ok   "容器 $c $status" ;;
            *)           warn "容器 $c 状态异常：$status" ;;
        esac
    done
}

# ---------------------------------------------------------------- MySQL
check_mysql() {
    local ip=$1 holder=$2
    local q sid ro sro

    q=$(remote_mysql "$ip" "SELECT CONCAT_WS('|', @@server_id, @@global.read_only, @@global.super_read_only)")
    if [ -z "$q" ]; then
        fail "MySQL 不可访问"
        return
    fi
    IFS='|' read -r sid ro sro <<< "$q"
    info "server_id=$sid read_only=$ro super_read_only=$sro"

    if [ "$holder" = 1 ]; then
        if [ "$ro" = "0" ] && [ "$sro" = "0" ]; then
            ok "主库可写"
        else
            fail "主库处于只读（read_only=$ro super_read_only=$sro）"
        fi
        # 主库上残留的复制通道不影响服务，只提示
        local io
        io=$(remote_mysql_vertical "$ip" 'SHOW SLAVE STATUS\G' | awk -F': ' '/Slave_IO_Running:/{print $2}')
        [ -n "$io" ] && info "主库上存在复制通道（IO=$io），无需复制，可忽略"
    else
        [ "$ro" = "1" ] && ok "备库只读（read_only=1）" || warn "备库 read_only=$ro（建议置 1）"

        local st io sql_r lag mh err
        st=$(remote_mysql_vertical "$ip" 'SHOW SLAVE STATUS\G')
        if [ -z "$st" ]; then
            fail "备库未配置复制关系"
            return
        fi
        io=$(printf '%s\n' "$st" | awk -F': ' '/Slave_IO_Running:/{print $2}')
        sql_r=$(printf '%s\n' "$st" | awk -F': ' '/Slave_SQL_Running:/{print $2}')
        lag=$(printf '%s\n' "$st" | awk -F': ' '/Seconds_Behind_Master:/{print $2}')
        mh=$(printf '%s\n' "$st" | awk -F': ' '/Master_Host:/{print $2}')
        err=$(printf '%s\n' "$st" | awk -F': ' '/Last_SQL_Error:/{print $2}')

        if [ "$io" = "Yes" ] && [ "$sql_r" = "Yes" ]; then
            ok "MySQL 复制正常（IO=Yes SQL=Yes 延迟=${lag:-N/A}s）"
        else
            fail "MySQL 复制异常（IO=${io:-N/A} SQL=${sql_r:-N/A} 延迟=${lag:-N/A}）"
            [ -n "$err" ] && info "Last_SQL_Error: ${err:0:200}"
        fi
        [ "$mh" = "$MYSQL_VIP" ] && ok "复制源为 VIP $MYSQL_VIP" \
            || warn "复制源为 ${mh:-未知}（预期 $MYSQL_VIP）"
    fi
}

# ---------------------------------------------------------------- Redis
check_redis() {
    local ip=$1 holder=$2
    local out role
    out=$(ssh_run "$ip" "docker exec redis redis-cli -a '$REDIS_PASS' info replication")
    if [ -z "$out" ]; then
        fail "Redis 不可访问"
        return
    fi
    role=$(printf '%s\n' "$out" | awk -F: '/^role:/{print $2}' | tr -d '\r')

    if [ "$holder" = 1 ]; then
        if [ "$role" != "master" ]; then
            fail "Redis 角色为 ${role:-未知}（预期 master）"
            return
        fi
        local slaves
        slaves=$(printf '%s\n' "$out" | awk -F: '/^connected_slaves:/{print $2}' | tr -d '\r')
        if [ "${slaves:-0}" -ge 1 ] 2>/dev/null; then
            ok "Redis master，从节点 ${slaves} 个"
        else
            warn "Redis master，但 connected_slaves=${slaves:-0}"
        fi
    else
        if [ "$role" != "slave" ]; then
            fail "Redis 角色为 ${role:-未知}（预期 slave）"
            return
        fi
        local link lag
        link=$(printf '%s\n' "$out" | awk -F: '/^master_link_status:/{print $2}' | tr -d '\r')
        lag=$(printf '%s\n' "$out" | awk -F: '/^master_last_io_seconds_ago:/{print $2}' | tr -d '\r')
        if [ "$link" = "up" ]; then
            ok "Redis slave，链路 up（最后 IO ${lag:-N/A}s 前）"
        else
            fail "Redis slave，master_link_status=${link:-未知}"
        fi
    fi
}

# ---------------------------------------------------------------- etcd
check_etcd() {
    local ip=$1
    local eps="http://$NODE1:2379,http://$NODE2:2379,http://$MYSQL_VIP:23790"
    local out healthy total
    out=$(ssh_run "$ip" "docker exec etcd etcdctl --endpoints=$eps endpoint health")
    if [ -z "$out" ]; then
        fail "etcdctl 无输出"
        return
    fi
    healthy=$(printf '%s\n' "$out" | grep -c 'is healthy')
    total=3
    if [ "$healthy" -eq "$total" ]; then
        ok "etcd ${healthy}/${total} 端点健康"
    else
        fail "etcd ${healthy}/${total} 端点健康"
        printf '%s\n' "$out" | grep -v 'is healthy' | sed 's/^/         /'
    fi

    # leader / 成员数
    local status
    status=$(ssh_run "$ip" "docker exec etcd etcdctl --endpoints=http://$MYSQL_VIP:23790 endpoint status --write-out=table")
    local leader
    leader=$(printf '%s\n' "$status" | awk -F'|' 'NF>5 && $6 ~ /true/{gsub(/ /,"",$2); print $2}')
    [ -n "$leader" ] && info "etcd leader：$leader"
}

# ---------------------------------------------------------------- 时间同步
check_time() {
    local ip=$1
    local out leap stratum offset
    out=$(ssh_run "$ip" 'chronyc tracking')
    if [ -z "$out" ]; then
        warn "chronyc 不可用，无法确认时间同步"
        return
    fi
    leap=$(printf '%s\n' "$out" | awk -F': *' '/Leap status/{print $2}' | tr -d '\r')
    stratum=$(printf '%s\n' "$out" | awk -F': *' '/Stratum/{print $2}' | tr -d '\r')
    offset=$(printf '%s\n' "$out" | awk -F': *' '/System time/{print $2}' | tr -d '\r')
    if [ "$leap" = "Normal" ]; then
        ok "chrony 同步正常（stratum=${stratum:-?}，${offset:-偏移未知}）"
    else
        fail "chrony Leap status=${leap:-未知}"
    fi
}

# ---------------------------------------------------------------- HA 日志
check_ha_log() {
    local ip=$1
    local tail
    tail=$(ssh_run "$ip" 'tail -n 200 /home/sder/ha/replica/logs/keepalived-wrapper.log')
    if [ -z "$tail" ]; then
        info "无 HA 日志"
        return
    fi
    info "HA 日志最后一行：$(printf '%s\n' "$tail" | tail -1)"

    # 只有“最近一次事件”是失败才告警；恢复后出现“检查通过”就不再翻旧账
    local last_ok last_fail last_broken
    last_ok=$(printf '%s\n' "$tail" | grep -n '检查通过' | tail -1 | cut -d: -f1)
    last_fail=$(printf '%s\n' "$tail" | grep -n 'Host key verification failed' | tail -1 | cut -d: -f1)
    last_broken=$(printf '%s\n' "$tail" | grep -n '重建后复制仍未建立' | tail -1 | cut -d: -f1)

    if [ -n "$last_fail" ] && { [ -z "$last_ok" ] || [ "$last_fail" -gt "$last_ok" ]; }; then
        warn "最近一次自动重建从库失败：SSH 主机密钥校验不过（known_hosts 里的 VIP 记录与当前持有者不符）"
    elif [ -n "$last_broken" ] && { [ -z "$last_ok" ] || [ "$last_broken" -gt "$last_ok" ]; }; then
        warn "最近一次自动重建从库失败"
    fi
}

# ---------------------------------------------------------------- VIP 服务路径
check_vip_services() {
    section "VIP 服务路径（本机 -> $MYSQL_VIP）"
    local p
    for p in 3306 6379 23790; do
        if timeout 3 bash -c "exec 3<>/dev/tcp/$MYSQL_VIP/$p" 2>/dev/null; then
            ok "TCP $MYSQL_VIP:$p 可达"
        else
            fail "TCP $MYSQL_VIP:$p 不可达"
        fi
    done

    [ -n "$HOLDER" ] || return
    local ro pong
    ro=$(ssh_run "$HOLDER" "docker exec mysql mysql -h'$MYSQL_VIP' -u'$MYSQL_USER' -p'$MYSQL_PASS' -N -e 'SELECT @@global.read_only'")
    [ "$ro" = "0" ] && ok "MySQL via VIP 可写" || fail "MySQL via VIP 不可写（read_only=${ro:-无响应}）"
    pong=$(ssh_run "$HOLDER" "docker exec redis redis-cli -h '$MYSQL_VIP' -a '$REDIS_PASS' ping" | tr -d '\r')
    [ "$pong" = "PONG" ] && ok "Redis via VIP 可应答" || fail "Redis via VIP 无应答（${pong:-空}）"
}

# ---------------------------------------------------------------- main
printf '%s\n' "replica 集群巡检  $(date '+%F %T %Z')  节点: $NODE1 / $NODE2  VIP: $VIPS_LIST（数据面 $MYSQL_VIP）"
printf '%s\n' "从 $(hostname)（$(hostname -I | awk '{print $1}')）探测"

# 先确认可达，并找出 VIP 持有者
section "节点可达性"
reachable=()
for ip in "$NODE1" "$NODE2"; do
    name="node1"
    [ "$ip" = "$NODE2" ] && name="node2"
    if check_node "$ip" "$name"; then
        reachable+=("$ip")
        [ "$NODE_HOLDER" = 1 ] && HOLDER=$ip
    fi
done

section "VIP 归属"
if [ -z "$HOLDER" ]; then
    fail "没有任何节点持有数据面 VIP $MYSQL_VIP"
else
    local_split=0
    for v in "${VIPS[@]}"; do
        v=${v%%/*}
        n=0
        for ip in "${reachable[@]}"; do
            ssh_run "$ip" "ip -4 addr show dev $IFACE | grep -q 'inet $v/'" && n=$((n + 1))
        done
        [ "$n" -le 1 ] || { fail "VIP $v 同时被 $n 个节点持有（脑裂）"; local_split=1; }
    done
    if [ "$local_split" -eq 0 ]; then
        ok "VIP 整组由 $HOLDER 唯一持有（$VIPS_LIST）"
    fi
fi

for ip in "${reachable[@]}"; do
    holder=0; [ "$ip" = "$HOLDER" ] && holder=1
    name="node1"; [ "$ip" = "$NODE2" ] && name="node2"
    section "$name ($ip) 服务状态"
    check_containers "$ip" "$holder"
    check_mysql "$ip" "$holder"
    check_redis "$ip" "$holder"
    if [ "$holder" = 1 ]; then
        check_etcd "$ip"
    fi
    check_time "$ip"
    check_core_health "$ip"
    check_ha_log "$ip"
done

check_vip_services

# ---------------------------------------------------------------- 汇总
printf '\n%s== 汇总 ==%s\n' "$C_HDR" "$C_RST"
printf '  OK=%d  WARN=%d  FAIL=%d\n' "$OK" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '  %sFAIL 项：%s\n' "$C_FAIL" "$C_RST"
    printf '    - %s\n' "${FAIL_MSGS[@]}"
fi
if [ "$WARN" -gt 0 ]; then
    printf '  %sWARN 项：%s\n' "$C_WARN" "$C_RST"
    printf '    - %s\n' "${WARN_MSGS[@]}"
fi

[ "$FAIL" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0
