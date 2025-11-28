#!/bin/bash
set -e

read -p "请输入 nodeid: " NODEID
read -p "请输入 nodeip: " NODEIP

MY_CNF="$(dirname "$0")/mysql/config/my.cnf"
ROUTER_CONF="$(dirname "$0")/mysqlrouter/config/mysqlrouter.conf"

echo "更新 .env..."
ENV_FILE="$(dirname "$0")/.env"
sed -i "s/^NODEID=.*/NODEID=${NODEID}/" "$ENV_FILE"
sed -i "s/^NODEIP=.*/NODEIP=${NODEIP}/" "$ENV_FILE"

echo "更新 my.cnf..."
sed -i "s/^server-id=.*/server-id=${NODEID}/" "$MY_CNF"
sed -i "s/^report-host=.*/report-host=${NODEIP}/" "$MY_CNF"

echo "更新 mysqlrouter.conf..."
sed -i "s/^router_id = .*/router_id = ${NODEID}/" "$ROUTER_CONF"

echo "配置已更新。"
echo "如需重启服务，请手动执行 docker-compose down && docker-compose up -d "
