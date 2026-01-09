#!/bin/bash
# 验证数据一致性

source ./config.sh

echo "=== 数据一致性验证 ==="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"

# 获取最新的两个检查点
CHECKPOINTS=$(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -N -e "
SELECT 
    GROUP_CONCAT(CONCAT(checkpoint_id, '|', node_ip, '|', total_rows, '|', max_id))
FROM (
    SELECT checkpoint_id, node_ip, total_rows, max_id 
    FROM switch_checkpoint 
    ORDER BY checkpoint_id DESC 
    LIMIT 2
) t" | tr '|' ' ')

read CP1_ID CP1_IP CP1_ROWS CP1_MAXID CP2_ID CP2_IP CP2_ROWS CP2_MAXID <<< $(echo $CHECKPOINTS | awk '{print $1, $2, $3, $4, $5, $6, $7, $8}')

echo "检查点1 (ID:$CP1_ID): 节点=$CP1_IP, 行数=$CP1_ROWS, 最大ID=$CP1_MAXID"
echo "检查点2 (ID:$CP2_ID): 节点=$CP2_IP, 行数=$CP2_ROWS, 最大ID=$CP2_MAXID"

# 验证结果文件
VERIFY_RESULT="$REPORT_DIR/verify_result_$(date +%Y%m%d_%H%M%S).txt"

# 1. 验证记录总数增长
echo "1. 验证记录总数..." | tee $VERIFY_RESULT
if [ $CP2_ROWS -ge $CP1_ROWS ]; then
    ROW_INCREASE=$((CP2_ROWS - CP1_ROWS))
    echo "  ✅ 记录总数正常增长: +$ROW_INCREASE 行" | tee -a $VERIFY_RESULT
else
    echo "  ❌ 记录总数异常: 减少了 $((CP1_ROWS - CP2_ROWS)) 行" | tee -a $VERIFY_RESULT
fi

# 2. 验证ID连续性
echo "2. 验证ID连续性..." | tee -a $VERIFY_RESULT
ID_GAPS=$(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -N -e "
SELECT COUNT(*) as gap_count FROM (
    SELECT t1.id + 1 as missing_id
    FROM $TEST_TABLE t1
    LEFT JOIN $TEST_TABLE t2 ON t2.id = t1.id + 1
    WHERE t2.id IS NULL AND t1.id < (SELECT MAX(id) FROM $TEST_TABLE)
) gaps" 2>/dev/null)

if [ "$ID_GAPS" -eq 0 ]; then
    echo "  ✅ ID序列连续无断层" | tee -a $VERIFY_RESULT
else
    echo "  ❌ 发现 $ID_GAPS 个ID断层" | tee -a $VERIFY_RESULT
    
    # 显示具体的断层
    mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -e "
    SELECT 
        t1.id + 1 as gap_start,
        MIN(t3.id) - 1 as gap_end,
        MIN(t3.id) - t1.id - 1 as gap_size
    FROM $TEST_TABLE t1
    LEFT JOIN $TEST_TABLE t2 ON t2.id = t1.id + 1
    LEFT JOIN $TEST_TABLE t3 ON t3.id > t1.id
    WHERE t2.id IS NULL 
      AND t3.id IS NOT NULL
    GROUP BY t1.id
    HAVING gap_size > 0
    LIMIT 5" | tee -a $VERIFY_RESULT
fi

# 3. 验证数据完整性（抽样检查）
echo "3. 抽样数据验证..." | tee -a $VERIFY_RESULT
SAMPLE_SIZE=100
SAMPLE_START=$((CP1_MAXID - 200))
SAMPLE_END=$CP2_MAXID

if [ $SAMPLE_START -lt 1 ]; then
    SAMPLE_START=1
fi

mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -e "
SELECT 
    '抽样范围: ID ' || $SAMPLE_START || ' 到 ' || $SAMPLE_END as info,
    COUNT(*) as total_in_range,
    SUM(CASE WHEN tx_hash = MD5(CONCAT(id, account_id, amount, balance)) THEN 1 ELSE 0 END) as hash_matches,
    MIN(tx_time) as earliest_time,
    MAX(tx_time) as latest_time
FROM $TEST_TABLE 
WHERE id BETWEEN $SAMPLE_START AND $SAMPLE_END" | tee -a $VERIFY_RESULT

# 4. 验证业务逻辑（账户余额一致性）
echo "4. 验证业务逻辑一致性..." | tee -a $VERIFY_RESULT
mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -e "
SELECT 
    account_id,
    COUNT(*) as tx_count,
    SUM(amount) as total_amount,
    MIN(balance) as min_balance,
    MAX(balance) as max_balance,
    CASE 
        WHEN MAX(balance) - MIN(balance) = SUM(amount) 
        THEN '✅ 平衡' 
        ELSE '❌ 不平衡' 
    END as balance_check
FROM $TEST_TABLE 
WHERE account_id IN (
    SELECT DISTINCT account_id 
    FROM $TEST_TABLE 
    ORDER BY RAND() 
    LIMIT 5
)
GROUP BY account_id
ORDER BY account_id" | tee -a $VERIFY_RESULT

# 5. 验证索引完整性
echo "5. 验证索引完整性..." | tee -a $VERIFY_RESULT
mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -e "
SELECT 
    TABLE_NAME,
    INDEX_NAME,
    NON_UNIQUE,
    SEQ_IN_INDEX,
    COLUMN_NAME,
    CARDINALITY
FROM INFORMATION_SCHEMA.STATISTICS 
WHERE TABLE_SCHEMA = '$TEST_DB' 
  AND TABLE_NAME = '$TEST_TABLE'
ORDER BY INDEX_NAME, SEQ_IN_INDEX" | tee -a $VERIFY_RESULT

# 汇总验证结果
echo "=== 验证结果汇总 ===" | tee -a $VERIFY_RESULT
echo "验证时间: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a $VERIFY_RESULT
echo "VIP地址: $VIP" | tee -a $VERIFY_RESULT
echo "当前主库: $(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS -e "SELECT @@hostname" 2>/dev/null)" | tee -a $VERIFY_RESULT
echo "数据库: $TEST_DB" | tee -a $VERIFY_RESULT
echo "数据表: $TEST_TABLE" | tee -a $VERIFY_RESULT
echo "总行数: $(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -N -e "SELECT COUNT(*) FROM $TEST_TABLE")" | tee -a $VERIFY_RESULT
echo "最大ID: $(mysql -h $VIP -u $MYSQL_USER -p$MYSQL_PASS $TEST_DB -N -e "SELECT MAX(id) FROM $TEST_TABLE")" | tee -a $VERIFY_RESULT

echo "验证完成! 详细结果: $VERIFY_RESULT"