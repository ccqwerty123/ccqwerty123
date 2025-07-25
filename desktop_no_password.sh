#!/bin/bash

# ===================================================================================
# ==   一键式 XFCE 桌面安装与无密码启动脚本 v4.2 (版本号验证版)             ==
# ===================================================================================
# == 作者: Kilo Code (经 Gemini 整合与增强)                                       ==
# == 功能: 在一个全新的 Debian/Ubuntu 系统上，一键安装并以无密码模式启动服务。    ==
# ==       1. 安装 XFCE 桌面、中文字体等。                                     ==
# ==       2. 安装 TigerVNC 和 noVNC。                                         ==
# ==       3. 安装常用软件：Firefox, VSCode。                                    ==
# ==       4. 脚本可安全地重复运行，自动检测并清理旧服务，确保稳定启动。         ==
# ===================================================================================
#
# == ⚠️ 安全警告: 此脚本配置的VNC服务没有密码，请仅在绝对受信任的网络环境中使用！ ==
#
# == 使用方法:
# ==   1. 彻底删除旧脚本，将此完整代码保存为 desktop_no_password.sh
# ==   2. 赋予执行权限: chmod +x desktop_no_password.sh
# ==   3. 使用 root 权限运行: sudo ./desktop_no_password.sh
# ==   4. 检查输出的第一行是否为 v4.2
#
# ===================================================================================

# --- 全局配置 ---
SCRIPT_VERSION="4.2"              # 脚本版本号，用于验证
VNC_USER="desktop"                # VNC 运行的用户名
VNC_PORT="5901"                   # VNC 端口
NOVNC_PORT="6080"                 # noVNC 网页端口
VNC_GEOMETRY="1920x1080"          # 桌面分辨率
VNC_DEPTH="24"                    # 颜色深度
DISPLAY_NUM="1"                   # VNC 显示器编号 (与 VNC_PORT 对应)

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- 安装完成标记文件 ---
INSTALL_FLAG_FILE="/etc/desktop_no_password.installed"

# ===================================================================================
# ==                             辅助功能函数 (自包含)                             ==
# ===================================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要以 root 权限运行。"
        log_info "请使用: sudo $0 $*"
        exit 1
    fi
}

# ===================================================================================
# ==                           核心安装流程 (仅首次运行)                           ==
# ===================================================================================

install_environment() {
    log_info "====================================================="
    log_info "==      首次运行，开始执行完整的环境安装流程...      =="
    log_info "====================================================="
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends software-properties-common curl wget git nano sudo dbus-x11 gpg
    apt-get install -y --no-install-recommends xfce4 xfce4-goodies xfce4-terminal fonts-wqy-zenhei fonts-wqy-microhei fcitx5
    apt-get install -y --no-install-recommends tigervnc-standalone-server novnc websockify
    apt-get install -y --no-install-recommends firefox-esr
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/microsoft.gpg
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
    apt-get update -y
    apt-get install -y code
    if ! id "$VNC_USER" &>/dev/null; then useradd -m -s /bin/bash "$VNC_USER"; adduser "$VNC_USER" sudo; fi
    sudo -u "$VNC_USER" mkdir -p "/home/$VNC_USER/.vnc"
    cat > "/home/$VNC_USER/.vnc/xstartup" <<EOF
#!/bin/bash
export XDG_CURRENT_DESKTOP="XFCE"
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
    chmod +x "/home/$VNC_USER/.vnc/xstartup"
    chown -R "$VNC_USER":"$VNC_USER" "/home/$VNC_USER/.vnc"
    apt-get autoremove -y >/dev/null; apt-get clean; rm -rf /var/lib/apt/lists/*
    touch "$INSTALL_FLAG_FILE"
    log_success "======================================================="
    log_success "==         🎉 环境安装成功！🎉         =="
    log_success "======================================================="
    sleep 3
}

# ===================================================================================
# ==                         服务管理与启动 (每次运行)                           ==
# ===================================================================================

stop_existing_services() {
    log_info "正在彻底清理旧的 VNC 和 noVNC 进程..."
    sudo -u "$VNC_USER" vncserver -kill ":$DISPLAY_NUM" >/dev/null 2>&1
    pkill -u "$VNC_USER" -f "Xtigervnc.*:$DISPLAY_NUM" >/dev/null 2>&1
    pkill -f "websockify.*$NOVNC_PORT" >/dev/null 2>&1
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" >/dev/null 2>&1
    sleep 1
    log_info "服务清理完成。"
}

start_vnc_service() {
    log_info "正在以无密码模式启动 VNC 服务器..."
    # 关键参数: -SecurityTypes None 表示不需要任何安全验证
    # 新增 --I-KNOW-THIS-IS-INSECURE 来绕过新版VNC的安全检查
    sudo -u "$VNC_USER" vncserver ":$DISPLAY_NUM" \
        -depth "$VNC_DEPTH" \
        -geometry "$VNC_GEOMETRY" \
        -localhost no \
        -SecurityTypes None \
        --I-KNOW-THIS-IS-INSECURE
    
    sleep 2
    if pgrep -u "$VNC_USER" -f "Xtigervnc.*:$DISPLAY_NUM" >/dev/null; then
        log_success "VNC 服务器（无密码模式）启动成功！"
    else
        log_error "VNC 服务器启动失败，请检查日志。"
        exit 1
    fi
}

start_novnc_service() {
    log_info "正在启动 noVNC (网页客户端) 服务..."
    websockify -D --web=/usr/share/novnc/ "$NOVNC_PORT" "localhost:$VNC_PORT"
    
    sleep 2
    if pgrep -f "websockify.*$NOVNC_PORT" >/dev/null; then
        log_success "noVNC 服务启动成功！"
    else
        log_error "noVNC 服务启动失败，请检查 websockify 是否安装正确。"
        exit 1
    fi
}

show_service_info() {
    IP_ADDRESS=$(curl -s http://ipecho.net/plain || hostname -I | awk '{print $1}')
    echo
    log_info "================================================================"
    log_success "  🎉 所有服务已启动！现在可以通过浏览器访问远程桌面。 🎉"
    log_info "================================================================"
    echo
    echo -e "${YELLOW}访问地址:${NC} http://${IP_ADDRESS}:${NOVNC_PORT}/vnc.html"
    echo
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!! 安全警告 !!!!!!!!!!!!!!!!!!!!"
    echo -e "${RED}!!  此 VNC 连接未设置密码，任何人都可以访问！   !!"
    echo -e "${RED}!!  请仅在完全受信任的网络环境中使用此配置！    !!"
    echo -e "${RED}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
}

# ===================================================================================
# ==                                主函数入口                                   ==
# ===================================================================================
main() {
    check_root
    
    # **新增**：在脚本最开始输出版本号
    log_info "正在运行脚本版本: ${GREEN}${SCRIPT_VERSION}${NC}"

    if [ ! -f "$INSTALL_FLAG_FILE" ]; then
        install_environment
    else
        log_success "检测到环境已安装，将直接启动服务。"
    fi
    stop_existing_services
    start_vnc_service
    start_novnc_service
    show_service_info
}

# --- 执行脚本 ---
main "$@"
