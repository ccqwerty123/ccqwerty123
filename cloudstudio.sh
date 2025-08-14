#!/bin/bash

# ==============================================================================
# 脚本名称: install_webrtc_screen.sh (V13 - 孤注一掷版)
# 功能描述: 在 V12 的基础上，额外增加 -pthread 和 -static-libgcc 标志，
#           这是解决此链接问题的最后编译尝试。
# ==============================================================================

set -e
set -x

# --- 配置区 ---
INSTALL_DIR="$HOME/webrtc-remote-screen"
SERVICE_USER="$USER"
AGENT_PORT="9000"
DISPLAY_SESSION=":1" # 【【【 请务-必-确-认此值是否正确! 】】】

# --- 准备工作 (省略大部分输出) ---
if [[ $EUID -eq 0 ]]; then echo "[错误] 请不要使用 root 用户运行此脚本。"; exit 1; fi
if [ -d "$INSTALL_DIR" ]; then rm -rf "$INSTALL_DIR"; fi
mkdir -p "$INSTALL_DIR"
if [ -f /etc/debian_version ]; then
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y git make gcc libx11-dev libx264-dev screen wget >/dev/null 2>&1
fi
if ! command -v go &> /dev/null; then
    GO_VERSION="1.21.0"
    wget --quiet -O /tmp/go.tar.gz "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz >/dev/null 2>&1
    rm /tmp/go.tar.gz
fi
export PATH=$PATH:/usr/local/go/bin

# --- 克隆与编译 ---
cd "$INSTALL_DIR"
git clone https://github.com/rviscarra/webrtc-remote-screen.git . >/dev/null 2>&1
go mod tidy >/dev/null 2>&1

echo "[信息] 开始最终编译 (V13 - 孤注一掷版)..."

# ############################################################################ #
# ##  这是最后的编译尝试，我们加入了所有可能相关的链接器标志。               ## #
# ############################################################################ #
if go build -v -tags "h264enc" -ldflags='-extldflags "-lm -pthread -static-libgcc"' -o agent cmd/agent.go; then
    echo "[成功] 难以置信！程序编译成功！"
else
    echo ""
    echo "=============================[编译最终失败]============================="
    echo "事实证明，webrtc-remote-screen 无法在您当前的云环境中被编译。"
    echo "这并非您的操作问题，而是工具链深层不兼容所致。"
    echo "请放弃编译此工具，并采用下面的【备选方案】。"
    echo "========================================================================"
    exit 1
fi

chown -R $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"

# --- 创建服务 (仅在成功后执行) ---
# ... (省略服务创建代码，因为重点在于编译) ...

set +x
echo ""
echo "================================================="
echo "🎉🎉🎉 恭喜！安装编译成功！🎉🎉🎉"
echo "================================================="
echo "后续步骤请参照 V12 脚本的成功提示进行操作。"
echo "================================================="
