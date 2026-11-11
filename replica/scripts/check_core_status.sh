#!/bin/bash
# 核心网 NF 健康判定，被 check_mysql_status.sh source，也可单独执行。
#
# 数据来源（只解析，绝不 source）：
#   本机：/var/run/coremgr_nf_health           —— coremgr 原子写入的 key=value
#   对端：http://<peer>:8888/coremgr/ha/health —— 同样的 key=value
#
# 判定原则：
#   - 数据缺失/过期 = 未知，不触发切换，只告警（避免探测故障导致误切）；
#   - enforce=0 = 观察模式，不参与切换；
#   - 本机 critical 网元确认故障（critical_down>0）且对端 ready=1 时才返回 1；
#   - BACKUP 永远返回 0。
source "/home/sder/ha/replica/scripts/base.sh"

# 单独执行（replica-runner.sh check-core）时没有 check_mysql_status.sh 的封装
if ! declare -F log_limited >/dev/null; then
    log_limited() {
        local key=$1 interval=$2 msg=$3 f="/var/run/replica_log_${1}" now last
        now=$(date +%s)
        last=$(cat "$f" 2>/dev/null || echo 0)
        if [ $((now - last)) -ge "$interval" ]; then
            echo "$now" > "$f"
            echo "[$(date '+%F %T')] $msg" >> "$LOG"
        fi
    }
fi
if ! declare -F send_notification >/dev/null; then
    send_notification() { log_limited "core_$1" 300 "[$2] $3"; }
fi
if ! declare -F notify_limited >/dev/null; then
    notify_limited() { log_limited "$1" "$2" "[$4] $5"; }
fi
if ! declare -F in_promotion >/dev/null; then
    in_promotion() {
        [ -f "$PROMOTE_FLAG" ] || return 1
        local started age
        started=$(cat "$PROMOTE_FLAG" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - started ))
        [ "$age" -ge 0 ] && [ "$age" -lt 120 ]
    }
fi

# 从标准输入读取 key=value
kv_get() {
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'
}

verdict_get() {   # verdict_get KEY  —— 读本机 verdict 文件
    [ -r "$NF_HEALTH_FILE" ] || return 1
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$NF_HEALTH_FILE" 2>/dev/null
}

# 本机 verdict 是否新鲜（updated 不超过 stale_after + 5s 抖动）
verdict_fresh() {
    local updated stale now
    [ -r "$NF_HEALTH_FILE" ] || return 1
    updated=$(verdict_get updated)
    stale=$(verdict_get stale_after)
    [ -n "$updated" ] && [ "$updated" -gt 0 ] 2>/dev/null || return 1
    stale=${stale:-20}
    now=$(date +%s)
    [ $((now - updated)) -le $((stale + 5)) ]
}

peer_health_url() {
    if [ -n "$COREMGR_HEALTH_URL" ]; then
        echo "$COREMGR_HEALTH_URL"
        return 0
    fi
    local p
    p=$(peer_ip)
    [ -n "$p" ] || return 1
    echo "http://${p}:${COREMGR_PORT}/coremgr/ha/health"
}

# 查询对端裁决；端点不可用（旧版本/未启动）时返回非 0。
peer_verdict() {
    command -v curl >/dev/null 2>&1 || return 1
    local url
    url=$(peer_health_url) || return 1
    curl -fsS --connect-timeout 1 --max-time 2 "$url" 2>/dev/null
}

core_gate_master() {
    # 观察模式：不参与切换
    [ "${CORE_GATE:-1}" = "1" ] || return 0

    if ! verdict_fresh; then
        notify_limited core_stale 300 MASTER WARNING \
            "本机核心网健康数据缺失或过期（${NF_HEALTH_FILE}），暂不按核心网状态切换"
        return 0
    fi

    local enforce ready state critical_down names switching
    enforce=$(verdict_get enforce)
    ready=$(verdict_get ready)
    state=$(verdict_get state)
    critical_down=$(verdict_get critical_down)
    names=$(verdict_get critical_down_names)
    switching=$(verdict_get switching)

    [ "$enforce" = "1" ] || return 0
    [ "$switching" = "1" ] && return 0
    [ "$ready" = "1" ] && return 0
    # 只是启动/重启宽限或 rise 阶段，还没有确认故障
    [ "${critical_down:-0}" = "0" ] && return 0
    # 本机正在提升（VIP 刚接管，NF 可能仍在启动）
    in_promotion && return 0

    local peer_out peer_ready
    if peer_out=$(peer_verdict); then
        peer_ready=$(printf '%s\n' "$peer_out" | kv_get ready)
        if [ "$peer_ready" = "1" ]; then
            send_notification MASTER ERROR \
                "核心网关键网元异常（${names:-${state}}），对端就绪，释放 VIP 触发切换（${LOCAL_IP}）"
            return 1
        fi
        notify_limited core_peer_block 300 MASTER WARNING \
            "核心网关键网元异常（${names:-${state}}），但对端核心网未就绪，暂不切换（${LOCAL_IP}）"
        return 0
    fi

    notify_limited core_peer_unreach 300 MASTER WARNING \
        "核心网关键网元异常（${names:-${state}}），对端健康接口不可用，暂不切换（${LOCAL_IP}）"
    return 0
}

# MySQL 硬故障时：对端核心网未就绪则暂不切换；端点不可用时按原逻辑切换。
# 返回 0 = 允许切换，1 = 暂不切换。
core_peer_ready_for_failover() {
    [ "${CORE_PEER_GATE_MYSQL:-1}" = "1" ] || return 0
    local out ready names state
    if out=$(peer_verdict); then
        ready=$(printf '%s\n' "$out" | kv_get ready)
        [ "$ready" = "1" ] && return 0
        names=$(printf '%s\n' "$out" | kv_get critical_down_names)
        state=$(printf '%s\n' "$out" | kv_get state)
        notify_limited core_peer_block_mysql 300 MASTER WARNING \
            "MySQL 不可用，但对端核心网未就绪（${names:-${state}}），暂不切换（${LOCAL_IP}）"
        return 1
    fi
    notify_limited core_peer_unreach_mysql 300 MASTER WARNING \
        "MySQL 不可用，对端核心网健康接口不可用，按原逻辑切换（${LOCAL_IP}）"
    return 0
}

core_gate_backup() {
    # 备节点不能返回失败，否则会进入 FAULT 而无法接管
    if verdict_fresh; then
        local ready names
        ready=$(verdict_get ready)
        names=$(verdict_get critical_down_names)
        if [ "$ready" != "1" ]; then
            log_limited core_backup_not_ready 300 \
                "BACKUP 核心网未就绪（critical_down=${names:-无}），不影响 keepalived 选举"
        fi
    fi
    return 0
}

core_status() {
    echo "=== 本机 coremgr 健康（${NF_HEALTH_FILE}） ==="
    if [ -r "$NF_HEALTH_FILE" ]; then
        cat "$NF_HEALTH_FILE"
    else
        echo "文件不存在：coremgr 未运行、未启用 nf_health，或仍为旧版本"
    fi
    echo
    local url
    if url=$(peer_health_url); then
        echo "=== 对端（${url}） ==="
        peer_verdict || echo "对端不可达或未启用"
    else
        echo "=== 对端 === 无法确定对端地址（LOCAL_IP=${LOCAL_IP}）"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-status}" in
        status) core_status ;;
        gate)   core_gate_master; exit $? ;;
        *)
            echo "usage: $0 {status|gate}" >&2
            exit 2
            ;;
    esac
fi
