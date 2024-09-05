#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以 root 权限运行" 1>&2
   exit 1
fi

# 检查 crontab 中是否存在旧的条目
if crontab -l | grep -q "x-ui restart"; then
    echo "发现旧的 crontab 条目。正在更新..."
    
    # 创建一个临时文件
    TEMP_CRON=$(mktemp)
    
    # 更新 crontab 内容
    crontab -l | sed 's|0 2 \* \* \* x-ui restart|0 2 * * * systemctl restart x-ui.service|g' > "$TEMP_CRON"
    
    # 应用新的 crontab
    crontab "$TEMP_CRON"
    
    # 删除临时文件
    rm "$TEMP_CRON"
    
    echo "crontab 更新成功。"
else
    echo "未找到旧的 crontab 条目。未做任何更改。"
fi

# 检查 /usr/local/x-ui/goxui.sh 文件是否存在
if [ -f "/usr/local/x-ui/goxui.sh" ]; then
    echo "正在更新 /usr/local/x-ui/goxui.sh..."
    
    # 备份原文件
    cp /usr/local/x-ui/goxui.sh /usr/local/x-ui/goxui.sh.bak
    
    # 写入新的内容，保持简洁
    cat > /usr/local/x-ui/goxui.sh << EOL
#!/bin/bash
if ! pgrep -x "x-ui" > /dev/null || ! pgrep -x "xray" > /dev/null; then
    echo 3 > /proc/sys/vm/drop_caches
    systemctl restart x-ui.service
fi
EOL

    echo "/usr/local/x-ui/goxui.sh 更新成功。"
else
    echo "未找到 /usr/local/x-ui/goxui.sh 文件。未做任何更改。"
fi

echo "脚本执行完成。"
