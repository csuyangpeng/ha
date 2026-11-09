#!/bin/bash
# keepalived 执行 replica 脚本的入口（仓库中的源文件）
#
# 为什么需要这一层：
#   keepalived 开启 enable_script_security 后，会校验脚本路径上每一级目录的属主。
#   /home/sder 属于普通用户，即使把下面的脚本 chown root:root + chmod 755，
#   仍会被判定为 insecure（keepalived -t 退出码 5：
#   "Disabling track script chk_mysql_ha due to insecure"）。
#   因此必须由 root 拥有的 /etc/keepalived/replica-runner.sh 转发一次。
#
# 部署（两台都执行，脚本更新后重新执行一次）：
#   sudo install -o root -g root -m 755 \
#       /home/sder/ha/replica/scripts/replica-runner.sh \
#       /etc/keepalived/replica-runner.sh
#
# keepalived 中这样引用：
#   script        "/etc/keepalived/replica-runner.sh check"
#   notify_master "/etc/keepalived/replica-runner.sh master"
#   notify_backup "/etc/keepalived/replica-runner.sh backup"
#   notify_fault  "/etc/keepalived/replica-runner.sh backup"
#   notify_stop   "/etc/keepalived/replica-runner.sh backup"

BASE="/home/sder/ha/replica/scripts"

case "${1:-}" in
    check)  exec "$BASE/check_mysql_status.sh" ;;
    master) exec "$BASE/notify_master.sh" ;;
    backup) exec "$BASE/notify_slave.sh" ;;
    *)
        echo "usage: $0 {check|master|backup}" >&2
        exit 2
        ;;
esac
