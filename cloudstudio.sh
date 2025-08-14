#!/bin/bash

# ==============================================================================
# 脚本名称: install_webrtc_screen.sh (V4 - 修复目录冲突 & 自动检测 systemd)
# 功能描述: 在已具备 XFCE/VNC 环境下，自动安装并配置 webrtc-remote-screen
# ==============================================================================

# --- 配置区 ---
INSTALL_DIR="$HOME/webrtc-remote-screen" # 程序安装目录
SERVICE_USER="$USER"                     # 运行服务的用户名 (通常无需修改)
AGENT_PORT="9000"                        # Web访问端口

# ############################################################################ #
# ##                                                                        ## #
# ##  【【【 请务必修改此项! 】】】                                           ## #
# ##  在您的 VNC 桌面中打开终端，运行 `echo $DISPLAY` 命令查看此值。          ## #
# ##  通常它的值是 :1 或 :2。                                                 ## #
# ##                                                                        ## #
   DISPLAY_SESSION=":1"
# ##                                                                        ## #
# ############################################################################ #

# --- 脚本初始化 ---
set -e
set -o pipefail

# --- 美化输出 ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'

info() { echo -e "${C_BLUE}[信息]${C_RESET} $1"; }
success() { echo -e "${C_GREEN}[成功]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[警告]${C_RESET} $1"; }
error() { echo -e "${C_RED}[错误]${C_RESET} $1"; exit 1; }

# --- 主程序 ---

# 步骤 1: 权限和配置检查
info "检查运行环境和配置..."
if [[ $EUID -eq 0 ]]; then
   error "请不要使用 root 用户运行此脚本。请切换到拥有 sudo 权限的普通用户。"
fi
if ! sudo -v; then
    error "无法获取 sudo 权限。请确保当前用户在 sudoers 列表中。"
fi
if [[ -z "$DISPLAY_SESSION" ]]; then
    error "关键配置 DISPLAY_SESSION 为空！请编辑脚本并设置正确的值 (如 ':1')。"
fi
success "环境检查通过。"

# 步骤 2: 清理和准备安装目录 (已修复)
if [ -d "$INSTALL_DIR" ]; then
    warn "检测到已存在的安装目录: $INSTALL_DIR"
    read -p "$(echo -e "${C_YELLOW}[提示]${C_RESET} 是否要删除旧目录并重新安装? [y/N]: ")" user_choice
    if [[ "$user_choice" =~ ^[Yy]$ ]]; then
        info "正在停止可能在运行的服务并删除旧的安装..."
        sudo systemctl stop webrtc-remote-screen.service >/dev/null 2>&1 || true
        sudo systemctl disable webrtc-remote-screen.service >/dev/null 2>&1 || true
        sudo rm -f /etc/systemd/system/webrtc-remote-screen.service >/dev/null 2>&1 || true
        rm -rf "$INSTALL_DIR"
        success "旧版本已清理。"
    else
        info "安装已取消。"
        exit 0
    fi
fi
mkdir -p "$INSTALL_DIR"

# 步骤 3: 安装编译依赖
info "准备安装编译依赖..."
if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt-get"
    DEPS="git make gcc libx11-dev libx264-dev screen" # 添加 screen 以备用
    info "检测到 Debian/Ubuntu 系统。"
elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
    if command -v dnf &> /dev/null; then PKG_MANAGER="dnf"; fi
    DEPS="git make gcc libX11-devel xz libx264-devel screen" # 添加 screen 以备用
    info "检测到 CentOS/RHEL 系统。"
else
    error "无法识别的操作系统，脚本无法继续。"
fi

info "正在更新软件包列表 (需要sudo权限)..."
sudo $PKG_MANAGER update -y >/dev/null 2>&1
info "正在安装依赖包: $DEPS..."
sudo $PKG_MANAGER install -y $DEPS

# 步骤 4: 安装 Go 语言环境
if ! command -v go &> /dev/null; then
    info "Go 环境未找到，现在开始自动安装..."
    GO_VERSION="1.21.0"
    GO_FILENAME="go${GO_VERSION}.linux-amd64.tar.gz"
    GO_TEMP_PATH="/tmp/$GO_FILENAME"
    DOWNLOAD_URL="https://golang.org/dl/$GO_FILENAME"
    info "正在从 $DOWNLOAD_URL 下载 Go 到 $GO_TEMP_PATH..."
    wget --quiet --continue -O "$GO_TEMP_PATH" "$DOWNLOAD_URL"
    [ ! -f "$GO_TEMP_PATH" ] && error "Go 安装包下载失败！"
    info "正在解压并安装 Go 到 /usr/local/go (需要sudo权限)..."
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$GO_TEMP_PATH"
    info "正在清理临时文件: $GO_TEMP_PATH"
    rm "$GO_TEMP_PATH"
    export PATH=$PATH:/usr/local/go/bin
    if ! grep -q "/usr/local/go/bin" "$HOME/.profile"; then
        echo -e '\n# Go Language Path\nexport PATH=$PATH:/usr/local/go/bin' >> "$HOME/.profile"
    fi
    success "Go 安装完成。"
    warn "为使 Go 命令在新的终端中生效，您可能需要重新登录或执行 'source ~/.profile'。"
else
    success "检测到已安装的 Go 环境。"
fi
export PATH=$PATH:/usr/local/go/bin

# 步骤 5: 克隆并编译 webrtc-remote-screen
info "准备下载和编译 webrtc-remote-screen..."
cd "$INSTALL_DIR"
info "正在从 GitHub 克隆源码..."
git clone https://github.com/rviscarra/webrtc-remote-screen.git . # 克隆到当前目录

info "正在修复和同步 Go 模块依赖..."
go mod tidy
success "依赖修复完成。"

info "开始编译程序 (这可能需要几分钟)..."
if make; then
    success "程序编译成功。"
else
    error "编译失败！请检查上面的错误信息。"
fi
chown -R $SERVICE_USER:$SERVICE_USER "$INSTALL_DIR"
[ ! -f "$INSTALL_DIR/agent" ] && error "未找到编译产物 'agent'，安装失败。"
success "webrtc-remote-screen 已成功安装到 $INSTALL_DIR"

# 步骤 6: 创建服务或提供手动指令 (已重构)
HAS_SYSTEMD=false
if command -v systemctl &> /dev/null && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD=true
fi

if [ "$HAS_SYSTEMD" = true ]; then
    info "检测到 systemd，正在创建服务..."
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
RestartSec=5

[Install]
WantedBy=multi-user.target"
    echo "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" > /dev/null
    sudo systemctl daemon-reload
    success "systemd 服务已创建。"
else
    warn "未检测到 systemd。将提供使用 'screen' 的手动启动指令。"
fi

# --- 完成 ---
echo
success "🎉 安装全部完成！"
echo
info "--- 【重要】后续操作指南 ---"
warn "1. 确认 VNC 会话正在运行！"
echo "   本服务依赖一个已存在的图形桌面会话。请确保您的 VNC Server 已经启动，"
echo "   并且创建了您在脚本中配置的桌面 ($DISPLAY_SESSION)。"
echo
warn "2. 配置防火墙"
echo "   您必须手动开放 Web 访问端口和 WebRTC 所需的 UDP 端口。"
echo "   - Web 访问端口: TCP $AGENT_PORT"
echo "   - WebRTC 数据端口 (建议范围): UDP 10000-20000"
echo

if [ "$HAS_SYSTEMD" = true ]; then
# systemd 指令
info "3. 管理服务 (使用 systemd)"
echo "   ▶ 启动服务:   sudo systemctl start webrtc-remote-screen.service"
echo "   ▶ 查看状态:   sudo systemctl status webrtc-remote-screen.service"
echo "   ▶ 开机自启:   sudo systemctl enable webrtc-remote-screen.service"
echo "   ▶ 停止服务:   sudo systemctl stop webrtc-remote-screen.service"
else
# screen 指令
info "3. 管理服务 (使用 screen)"
echo "   由于没有检测到 systemd，请使用以下命令手动在后台运行服务:"
echo "   ▶ 启动服务:   DISPLAY=$DISPLAY_SESSION screen -dmS webrtc $INSTALL_DIR/agent -p $AGENT_PORT"
echo "   ▶ 查看日志:   screen -r webrtc  (按 Ctrl+A 然后按 D 键可分离会话并使其在后台继续运行)"
echo "   ▶ 停止服务:   screen -X -S webrtc quit"
fi
echo
info "4. 开始使用"
echo "   服务启动且防火墙配置正确后，请在本地浏览器中访问:"
echo "   http://<你的服务器IP>:${AGENT_PORT}"
