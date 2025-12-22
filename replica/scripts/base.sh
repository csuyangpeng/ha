#!/bin/bash

_ts_pipe() {
  while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%a %b %d %I:%M:%S %p %Z %Y'):" "$line"
  done
}

LOG="/home/sder/ha/replica/logs/keepalived-wrapper.log"

MYSQL_USER="root"
MYSQL_PASS="s<9!Own1z4"
