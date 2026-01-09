#!/bin/bash
# 一键执行所有测试

source ./config.sh

echo "========================================"
echo "    MySQL高可用切换测试套件"
echo "========================================"
echo "VIP地址: $VIP"
echo "节点列表: ${KEEPALIVED_NODES[@]}"
echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# 执行测试步骤
echo "步骤1: 准备测试环境..."
./prepare_test.sh
if [ $? -ne 0 ]; then
    echo "❌ 准备阶段失败"
    exit 1
fi

echo -e "\n步骤2: 在后台启动监控..."
./monitor_switch.sh > $LOG_DIR/monitor_background.log 2>&1 &
MONITOR_PID=$!
echo "监控进程PID: $MONITOR_PID"

# 等待监控启动
sleep 3

echo -e "\n步骤3: 执行主库切换测试..."
./run_switch_test.sh
if [ $? -ne 0 ]; then
    echo "⚠️ 切换测试中有错误，但继续验证..."
fi

echo -e "\n步骤4: 停止监控..."
kill $MONITOR_PID 2>/dev/null

echo -e "\n步骤5: 验证数据一致性..."
./verify_consistency.sh

echo -e "\n步骤6: 生成测试报告..."
./generate_report.sh

echo "========================================"
echo "测试完成!"
echo "日志目录: $LOG_DIR"
echo "报告目录: $REPORT_DIR"
echo "========================================"