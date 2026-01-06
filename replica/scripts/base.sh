#!/bin/bash

_ts_pipe() {
  while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%a %b %d %I:%M:%S %p %Z %Y'):" "$line"
  done
}

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"

MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"

LOCK_FILE="/var/run/mysql_backup.lock"
THRESHOLD_FILE="/var/run/threshold_count"
THRESHOLD=1  # 阈值，达到3次才执行

MYSQL_VIP="10.18.1.30"
NODE1="10.18.1.27"
NODE2="10.18.1.28"

LOG_DIR="/home/sder/ha/replica/logs"
RESULT_DIR="/home/sder/ha/replica/results"
SCRIPT_DIR="/home/sder/ha/replica/scripts"


