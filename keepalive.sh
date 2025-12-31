#!/bin/bash
# ========================================================
# VPS 智能保活套装 (Sysctl优化 + 自动保活脚本 + 开机自启)
# 适用环境: Debian/Ubuntu/CentOS
# ========================================================

# 1. 权限检测
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限运行此脚本。"
  exit 1
fi

echo ">> 正在进行 VPS 智能保活部署..."

# ========================================================
# 2. Sysctl 内核参数优化 (检测是否存在，不存在则追加)
# ========================================================
echo "-> 检查并配置 sysctl.conf..."

SYSCTL_CONF="/etc/sysctl.conf"
declare -A SYS_PARAMS
SYS_PARAMS=(
    ["vm.swappiness"]="1"                   # 尽量不使用 swap，防卡死
    ["vm.vfs_cache_pressure"]="50"          # 保留文件系统缓存，减少IO
    ["vm.dirty_background_ratio"]="5"       # 后台脏数据写回阈值
    ["vm.dirty_ratio"]="30"                 # 脏数据最大阈值 (30% 比较安全，避免80%死机)
    ["vm.dirty_expire_centisecs"]="12000"   # 脏数据过期时间 120秒
    ["vm.dirty_writeback_centisecs"]="6000" # 写回进程唤醒间隔 60秒
)

has_changed=0

# 检查是否已经存在该参数 (忽略注释行)
for key in "${!SYS_PARAMS[@]}"; do
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF"; then
        echo "   [跳过] $key 已存在，保持原样。"
    else
        echo "   [添加] $key = ${SYS_PARAMS[$key]}"
        echo "$key = ${SYS_PARAMS[$key]}" >> "$SYSCTL_CONF"
        has_changed=1
    fi
done

if [ $has_changed -eq 1 ]; then
    echo "-> 应用 sysctl 参数..."
    sysctl -p >/dev/null 2>&1
else
    echo "-> sysctl 无需变动。"
fi

# ========================================================
# 3. 写入保活脚本 (使用 'EOF' 防止变量提前展开)
# ========================================================
SCRIPT_PATH="/root/keepalive.sh"
echo "-> 写入保活脚本到 $SCRIPT_PATH ..."

cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# VPS 智能保活脚本 - 自动网卡检测/低优先级/随机负载

while true; do
    # 1. 活跃检测 (SSH 连接)
    if [ $(ss -tn state established '( dport = :22 )' 2>/dev/null | wc -l) -gt 0 ]; then
        sleep 60
        continue
    fi

    # 2. 活跃检测 (全网卡流量 - 5秒窗口)
    get_bytes() { awk '/:/ {print $2, $10}' /proc/net/dev | awk '{s+=$1+$2} END {print s}'; }
    bytes_start=$(get_bytes)
    sleep 5
    bytes_end=$(get_bytes)
    
    if [ $((bytes_end - bytes_start)) -gt 20480 ]; then
        sleep 60
        continue
    fi

    # 3. 自身维护 (内存过高清理缓存)
    mem_usage=$(free | awk '/Mem/{printf("%.0f"), $3/$2*100}')
    if [ "$mem_usage" -ge 90 ]; then
        sync && echo 3 > /proc/sys/vm/drop_caches
        sleep 5
    fi

    # 4. 执行保活 (低优先级 nice -n 19)
    duration=$((RANDOM % 31 + 15))
    threads=$((RANDOM % $(nproc) + 1))

    for ((i=0; i<threads; i++)); do
        nice -n 19 timeout $duration openssl speed -evp aes-256-cbc >/dev/null 2>&1 &
    done

    # 20% 概率发送微小心跳包
    if (( RANDOM % 5 == 0 )); then
        curl -I -s --connect-timeout 3 https://www.google.com >/dev/null 2>&1 &
    fi

    wait
    # 随机休眠 30-90秒
    sleep $((RANDOM % 61 + 30))
done
EOF

chmod +x "$SCRIPT_PATH"

# ========================================================
# 4. 配置开机自启 (@reboot)
# ========================================================
echo "-> 配置 Crontab 开机自启..."

CRON_FILE="/tmp/cron_bk_$$" # 使用 $$ 获取当前进程ID，更安全
crontab -l 2>/dev/null > "$CRON_FILE" || true

# 检查是否已经存在该任务 (精确匹配命令路径)
if grep -qE "sleep[[:space:]]+10;[[:space:]]+${SCRIPT_PATH}" "$CRON_FILE"; then
    echo "   [跳过] 计划任务已存在。"
else
    # 追加 @reboot 任务，使用 ';' 分隔命令，并确保后台运行
    echo "@reboot sleep 10; $SCRIPT_PATH >/dev/null 2>&1 &" >> "$CRON_FILE"
    crontab "$CRON_FILE"
    echo "   [成功] 已添加 @reboot 任务。"
fi
rm -f "$CRON_FILE"

# ========================================================
# 5. 立即启动验证
# ========================================================
echo "-> 正在启动脚本..."
# 先杀掉旧进程防止重复
pkill -f "$SCRIPT_PATH"
# 后台启动
nohup "$SCRIPT_PATH" >/dev/null 2>&1 &

echo "========================================================"
echo "✅ 部署完成！"
echo "1. 内核参数已优化 (如 vm.swappiness=1)"
echo "2. 保活脚本已安装: $SCRIPT_PATH"
echo "3. 已设置开机自启，并已在后台运行。"
echo "========================================================"
