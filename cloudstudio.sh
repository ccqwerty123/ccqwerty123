#!/bin/bash

# =================================================================
#  一键安装运行工业级稳定桌面的终极脚本 (V20 - 稳定可靠版)
# =================================================================
#
# 版本: 20.0 (稳定版)
# 更新日期: 2025-07-15
#
# 特性:
# - V20 核心改进 (稳定压倒一切):
#   - 新增: 使用 `dbus-launch` 启动 LXDE，彻底修复 "no session for pid" 核心错误。
#     这将确保菜单、程序启动等所有桌面功能完全正常！
#   - 新增: 动态配置 LXDE，强制使用单一工作区，移除 desktop1/desktop2 的干扰。
#   - 移除: 彻底放弃脆弱的自适应分辨率，回归到稳定、可控的固定分辨率方案。
#   - 新增: 为 x11vnc 启用 "-ncache" 缓存选项，大幅提升流畅度。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="20.0"
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
#  请根据您自己的屏幕和浏览器窗口大小，修改为您最舒服的尺寸。
#  推荐的宽屏尺寸: "1366x768x24", "1600x900x24", "1920x1080x24"
# ============================================================================
SCREEN_RESOLUTION="1600x900x24"

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
echo -e "${GREEN}>>> 步骤 0/5: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "lxsession"; pkill -9 -f "dbus-daemon"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
# dbus-x11 包含 dbus-launch
if ! command -v startlxde &> /dev/null || ! command -v dbus-launch &> /dev/null; then
    echo "桌面环境未安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install lxde-core pcmanfm dbus-x11 xvfb x11vnc novnc websockify x11-utils -y --no-install-recommends \
        || handle_error "桌面环境或依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome 并创建菜单项 ---
echo -e "${GREEN}>>> 步骤 2/5: 准备Chrome并集成到桌面菜单...${NC}"
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
Version=1.0; Type=Application; Name=Google Chrome;
Comment=Access the Internet;
Icon=$(pwd)/chrome-unpacked/opt/google/chrome/product_logo_256.png
Exec=${CHROME_EXEC_PATH} --no-sandbox --disable-gpu --start-maximized
Terminal=false; Categories=Network;WebBrowser;
EOF
echo "Chrome准备就绪并已添加到'开始'菜单。"

# --- 步骤 3: 专业化配置桌面环境 ---
echo -e "${GREEN}>>> 步骤 3/5: 配置一个干净、单一的桌面环境...${NC}"
OPENBOX_CONFIG_DIR="$HOME/.config/openbox"; mkdir -p "${OPENBOX_CONFIG_DIR}"
# V20 关键改动: 配置单一工作区，移除 desktop1/2
cat << EOF > "${OPENBOX_CONFIG_DIR}/lxde-rc.xml"
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
  </desktops>
</openbox_config>
EOF
echo "桌面配置完成。"

# --- 步骤 4: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 4/5: 正在后台启动高稳定性的虚拟桌面...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM)); export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp); export XAUTHORITY=${XAUTH_FILE}

echo "  - 正在启动 Xvfb (固定分辨率: ${SCREEN_RESOLUTION})..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 10s bash -c "until xdpyinfo >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

# V20 关键改动: 使用 dbus-launch 启动 LXDE，修复核心BUG
echo "  - 正在启动 LXDE 桌面会话 (高稳定模式)..."
dbus-launch --exit-with-session lxsession -s LXDE -e LXDE &
sleep 5

echo "  - 正在启动 x11vnc (带性能优化)..."
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log -ncache 10
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功。"

# --- 步骤 5: 启动noVNC并提供最终指引 ---
echo -e "${GREEN}>>> 步骤 5/5: 正在启动noVNC网页服务...${NC}"
if [ ! -f "${NOVNC_PATH}/vnc_auto.html" ]; then
    handle_error "noVNC 网页文件 '${NOVNC_PATH}/vnc_auto.html' 不存在！"
fi

echo -e "\n${YELLOW}======================= 远程桌面使用指南 (V20 - 稳定版) ======================="
echo -e "一切就绪！这是一个【稳定可靠】的远程桌面。"
echo -e "请复制并打开下面的 【终极URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【干净的桌面】，没有多余的工作区。"
echo -e "  2. 点击左下角【开始菜单】->【互联网】->【Google Chrome】即可正常启动浏览器！"
echo -e "  3. '开始菜单' -> '附件' -> 'LXTerminal' 可以打开命令行终端。"
echo -e "${RED}  !!! 如何获得最佳显示效果? !!!${NC}"
echo -e "${RED}  如果桌面显示过大或过小，请【修改脚本开头的'SCREEN_RESOLUTION'变量】${NC}"
echo -e "${RED}  为您自己屏幕最合适的分辨率，然后重新运行此脚本。这是最可靠的方法！${NC}"
echo -e "${YELLOW}=================================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}
rm -f ${XAUTHORITY}
