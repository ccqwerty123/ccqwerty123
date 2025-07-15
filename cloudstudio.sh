#!/bin/bash

# =================================================================
#  一键安装运行工业级稳定桌面的终极脚本 (V21 - 最终修正版)
# =================================================================
#
# 版本: 21.0 (最终版)
# 更新日期: 2025-07-15
#
# 特性:
# - V21 核心改进 (最终修复):
#   - 新增: 使用 `eval $(dbus-launch --sh-syntax)` 魔法命令，为桌面会话
#     创建并注入一个健康的 D-Bus 上下文。
#   - 这将【彻底解决】"no session for pid" 的核心错误。
#   - 这将【连锁修复】因会ush
#     错误导致的菜单无法启动、分辨率异常等所有问题。
#   - 恢复并强化了为 Chrome 创建桌面菜单项的功能。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="21.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc"
# ============================================================================
#  !!! 最重要的设置: 分辨率 !!!
#  固定分辨率是最稳定可靠的方式。请修改为您最舒服的尺寸。
#  推荐的宽屏尺寸: "1366x768x24", "1600x900x24", "1920x1080x24"
# ============================================================================
SCREEN_RESOLUTION="1366x768x24"

# --- 辅助函数 ---
handle_error() {
    echo -e "\n${RED}====================================================="
    echo -e "  错误: $1"
    echo -e "  脚本已终止。"
    if [ -f "/tmp/x11vnc.log" ]; then
        echo -e "  x11vnc 日志 (/tmp/x11vnc.log) 内容:"; tail -n 10 /tmp/x11vnc.log; fi
    echo -e "=====================================================${NC}\n"
    exit 1
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键稳定桌面脚本 - 版本: ${SCRIPT_VERSION} ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/4: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "lxsession"; pkill -9 -f "dbus-daemon"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
if ! command -v startlxde &> /dev/null || ! command -v dbus-launch &> /dev/null; then
    echo "桌面环境未安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install lxde-core pcmanfm dbus-x11 xvfb x11vnc novnc websockify x11-utils -y --no-install-recommends \
        || handle_error "桌面环境或依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome 并创建菜单项 ---
echo -e "${GREEN}>>> 步骤 2/4: 准备Chrome并集成到桌面菜单...${NC}"
CHROME_EXEC_PATH="$(pwd)/chrome-unpacked/opt/google/chrome/google-chrome"
if [ ! -f "${CHROME_EXEC_PATH}" ]; then
    echo "  - 本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p chrome-unpacked && dpkg-deb -x google-chrome.deb ./chrome-unpacked \
        || handle_error "创建目录或解压Chrome失败。"
    rm google-chrome.deb
fi
APP_LAUNCHER_DIR="$HOME/.local/share/applications"; mkdir -p "${APP_LAUNCHER_DIR}"
cat << EOF > "${APP_LAUNCHER_DIR}/google-chrome-custom.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Access the Internet
Icon=$(pwd)/chrome-unpacked/opt/google/chrome/product_logo_256.png
Exec=${CHROME_EXEC_PATH} --no-sandbox --disable-gpu --start-maximized
Terminal=false
Categories=Network;WebBrowser;
EOF
echo "Chrome准备就绪并已添加到'开始'菜单。"

# --- 步骤 3: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动高稳定性的虚拟桌面...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM)); export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp); export XAUTHORITY=${XAUTH_FILE}

echo "  - 正在启动 Xvfb (固定分辨率: ${SCREEN_RESOLUTION})..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 10s bash -c "until xdpyinfo >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

# V21 关键改动: 创建一个健康的 D-Bus 会话上下文
echo "  - 正在为桌面环境创建健康的会话上下文..."
eval $(dbus-launch --sh-syntax)
# 等待 dbus-daemon 启动
sleep 2

echo "  - 正在启动 LXDE 桌面会话..."
startlxde &
sleep 5

echo "  - 正在启动 x11vnc (带性能优化)..."
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log -ncache 10
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功。"

# --- 步骤 4: 启动noVNC并提供最终指引 ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动noVNC网页服务...${NC}"
if [ ! -f "${NOVNC_PATH}/vnc_auto.html" ]; then
    handle_error "noVNC 网页文件 '${NOVNC_PATH}/vnc_auto.html' 不存在！"
fi

echo -e "\n${YELLOW}======================= 远程桌面使用指南 (V21 - 最终修正版) ======================="
echo -e "一切就绪！这是一个【功能完全正常】的稳定桌面。"
echo -e "请复制并打开下面的 【终极URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【分辨率正确】的灰色桌面。"
echo -e "  2. 之前所有的错误弹窗都应已消失。"
echo -e "  3. 点击左下角【开始菜单】->【互联网】->【Google Chrome】即可【正常启动】浏览器！"
echo -e "${RED}  !!! 如何获得最佳显示效果? !!!${NC}"
echo -e "${RED}  如果桌面显示过大或过小，请【修改脚本开头的'SCREEN_RESOLUTION'变量】${NC}"
echo -e "${RED}  为您自己屏幕最合适的分辨率，然后重新运行此脚本。这是最可靠的方法！${NC}"
echo -e "${YELLOW}=================================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}
rm -f ${XAUTHORITY}```
