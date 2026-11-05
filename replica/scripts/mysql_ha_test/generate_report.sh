#!/bin/bash
# 生成HTML测试报告

source ./config.sh

REPORT_FILE="$REPORT_DIR/test_report_$(date +%Y%m%d_%H%M%S).html"

cat > $REPORT_FILE << EOF
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>MySQL高可用切换测试报告</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
        h2 { color: #555; margin-top: 30px; }
        .summary { background: #f9f9f9; padding: 15px; border-left: 4px solid #4CAF50; }
        .success { color: #4CAF50; font-weight: bold; }
        .warning { color: #ff9800; font-weight: bold; }
        .error { color: #f44336; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        .timestamp { color: #666; font-size: 0.9em; }
    </style>
</head>
<body>
    <h1>MySQL高可用切换测试报告</h1>
    <div class="timestamp">生成时间: $(date '+%Y-%m-%d %H:%M:%S')</div>
    
    <div class="summary">
        <h2>测试概要</h2>
        <p><strong>VIP地址:</strong> $VIP</p>
        <p><strong>节点列表:</strong> ${KEEPALIVED_NODES[0]}, ${KEEPALIVED_NODES[1]}</p>
        <p><strong>测试数据库:</strong> $TEST_DB.$TEST_TABLE</p>
        <p><strong>压力测试:</strong> ${SYSBENCH_THREADS}线程, ${SYSBENCH_RATE}TPS, ${SYSBENCH_TIME}秒</p>
    </div>
    
    <h2>切换过程</h2>
    <pre style="background: #f5f5f5; padding: 15px; overflow: auto;">
EOF

# 添加切换日志
tail -50 $LOG_DIR/sysbench_during_switch.log >> $REPORT_FILE

cat >> $REPORT_FILE << EOF
    </pre>
    
    <h2>验证结果</h2>
EOF

# 添加验证结果
if [ -f "$REPORT_DIR/verify_result_*.txt" ]; then
    VERIFY_FILE=$(ls -t $REPORT_DIR/verify_result_*.txt | head -1)
    cat $VERIFY_FILE | sed 's/✅/<span class="success">✅<\/span>/g' | \
                     sed 's/⚠️/<span class="warning">⚠️<\/span>/g' | \
                     sed 's/❌/<span class="error">❌<\/span>/g' >> $REPORT_FILE
fi

cat >> $REPORT_FILE << EOF
    
    <h2>性能指标</h2>
    <table>
        <tr><th>指标</th><th>值</th><th>说明</th></tr>
EOF

# 获取性能指标
MYSQL_CMD="mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -N"

# 查询性能数据
TOTAL_ROWS=$($MYSQL_CMD $TEST_DB -e "SELECT COUNT(*) FROM $TEST_TABLE" 2>/dev/null)
MAX_ID=$($MYSQL_CMD $TEST_DB -e "SELECT MAX(id) FROM $TEST_TABLE" 2>/dev/null)
CHECKPOINTS=$($MYSQL_CMD $TEST_DB -e "SELECT COUNT(*) FROM switch_checkpoint" 2>/dev/null)

cat >> $REPORT_FILE << EOF
        <tr><td>总数据行数</td><td>$TOTAL_ROWS</td><td>测试表总记录数</td></tr>
        <tr><td>最大ID</td><td>$MAX_ID</td><td>自增ID当前值</td></tr>
        <tr><td>检查点数量</td><td>$CHECKPOINTS</td><td>记录的状态检查点</td></tr>
    </table>
    
    <h2>测试结论</h2>
    <div class="summary">
EOF

# 根据验证结果生成结论
if [ -f "$VERIFY_FILE" ]; then
    if grep -q "❌" "$VERIFY_FILE"; then
        echo "<p class='error'>❌ 测试发现数据不一致性问题，需要人工复核</p>" >> $REPORT_FILE
    elif grep -q "⚠️" "$VERIFY_FILE"; then
        echo "<p class='warning'>⚠️ 测试基本通过，但有警告信息</p>" >> $REPORT_FILE
    else
        echo "<p class='success'>✅ 所有验证通过，主库切换成功，数据一致</p>" >> $REPORT_FILE
    fi
fi

cat >> $REPORT_FILE << EOF
    </div>
    
    <h2>详细日志</h2>
    <ul>
        <li>准备阶段: <a href="file://$LOG_DIR/sysbench_prepare.log">sysbench_prepare.log</a></li>
        <li>切换过程: <a href="file://$LOG_DIR/sysbench_during_switch.log">sysbench_during_switch.log</a></li>
        <li>监控日志: <a href="file://$LOG_DIR/monitor_background.log">monitor_background.log</a></li>
    </ul>
    
    <hr>
    <div class="timestamp">
        测试环境: MySQL高可用集群 | Keepalived VIP切换<br>
        测试工具: Sysbench + 自定义验证脚本
    </div>
</body>
</html>
EOF

echo "HTML报告已生成: $REPORT_FILE"
echo "请在浏览器中打开查看: file://$REPORT_FILE"