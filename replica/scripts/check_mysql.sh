
#!/bin/bash
# 检查MySQL服务是否可用的简单脚本
if mysql -uroot -p's<9!Own1z4' -h 127.0.0.1 -e "SELECT 1;" &> /dev/null; then
    exit 0
else
    exit 1
fi
