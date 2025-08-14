#!/bin/bash

# ==============================================================================
# 脚本名称: install_webrtc_screen.sh (V10 - 文件执行版)
# 功能描述: 解决C语言链接错误和Bash语法错误的最终稳定版。
# ==============================================================================

set -e
set -x

# --- 配置区 ---
INSTALL_DIR="$HOME/webrtc-remote-screen"
SERVICE_USER="$USER"
AGENT_PORT="9000"
DISPLAY_SESSION=":1" # 【【【 请务必确认此值是否正确! 】】】

# --- 权限检查 ---
if [[ $EUID -eq 0 ]]; then
   echo "[错误] 请不要使用 root 用户运行此脚本。"
   exit 1
fi

# --- 清理旧目录 ---
echo "[信息] 准备安装目录: $INSTALL_DIR"
if [ -d "$INSTALL_DIR" ]; then
    echo "[警告] 检测到旧目录，将自动清理..."
    sudo systemctl stop webrtc-remote-screen.service >/dev/null 2>&1 || true
    sudo rm -f /etc/systemd/system/webrtc-remote-screen.service >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"

# --- 安装依赖 ---
echo "[信息] 准备安装编译依赖..."
if [ -f /etc/debian_version ]; then
    sudo apt-get update -y >/dev/null 2>&1
    sudo apt-get install -y git make gcc libx11-dev libx264-dev screen
elif [ -f /etc/redhat-release ]; then
    sudo yum install -y git make gcc libX11-devel xz libx264-devel screen
else
    echo "[错误] 无法识别的操作系统。"
    exit 1
fi

# --- 安装 Go ---
if ! command -v go &> /dev/null; then
    echo "[信息] 安装 Go 语言环境..."
    GO_VERSION="1.21.0"
    wget --quiet -O /tmp/go.tar.gz "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH=$PATH:/usr/local/go/bin
if ! grep -q "/usr/local/go/bin" "$HOME/.profile"; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.profile"
fi

# --- 克隆与编译 ---
echo "[信息] 克隆并编译源码..."
cd "$INSTALL_DIR"
git clone https://github.com/rviscarra/webrtc-remote-screen.git .
go mod tidy

echo "[信息] 开始最终编译..."
export CGO_CFLAGS="-std=gnu99"
export CGO_LDFLAGS="-lm"

if go build -tags "h264enc" -o agent cmd/agent.go; then
    echo "[成功] 程序编译成功！"
else
    echo "[错误] 编译失败！"
    exit 1
fi
chown -R $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"

# --- 创建服务 ---
echo "[信息] 创建 systemd 服务..."
HAS_SYSTEMD=false
if command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD=true
fi

if [ "$HAS_SYSTEMD" = true ]; then
    SERVICE_FILE="/etc/systemd/system/webrtc-remote-screen.service"
    SERVICE_CONTENT="[Unit]
Description=WebRTC Remote Screen Service
After=network.target
[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
Environment=\"DISPLAY=$DISPLAY_SESSION\"
ExecStart=$INSTALL_DIR/agent -p $AGENT_PORT
Restart=always
[Install]
WantedBy=multi-user.target"
    echo "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
    sudo systemctl daemon-reload
else
    echo "[警告] 未检测到 systemd。"
fi

# --- 完成 ---
set +x
echo ""
echo "================================================="
echo "🎉🎉🎉 安装脚本执行完毕！🎉🎉🎉"
echo "================================================="
echo "1. 服务已创建，但未启动。请先确保您的 VNC/XFCE 桌面 ($DISPLAY_SESSION) 正在运行。"
echo "2. 请务必配置防火墙，开放 TCP 端口 ${AGENT_PORT} 和 UDP 端口 10000-20000。"
echo ""
echo "▶ 启动服务:   sudo systemctl start webrtc-remote-screen.service"
echo "▶ 查看状态:   sudo systemctl status webrtc-remote-screen.service"
echo "▶ 开机自启:   sudo systemctl enable webrtc-remote-screen.service"
echo ""
echo "启动后，请访问: http://<你的服务器IP>:${AGENT_PORT}"
echo "================================================="
