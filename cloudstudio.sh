#!/bin/bash

# =================================================================
#  一键安装并运行完整服务器桌面的终极脚本 (V18 - 专业精装版)
# =================================================================
#
# 版本: 18.0
# 更新日期: 2025-07-15
#
# 特性:
# - V18 核心改进 (精装修与修复):
#   - 新增: 为Chrome动态创建标准的`.desktop`文件，完美解决菜单无法启动浏览器的问题。
#   - 新增: 配置LXDE会话，让PCManFM接管桌面并设置默认壁纸，彻底告别黑屏。
#   - 新增: 优化LXDE会话的启动方式，确保所有配置生效。
#   - 新增: 在最终说明中增加分辨率自定义的提示，提升用户体验。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="18.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc"
# 使用一个更安全、更通用的4:3分辨率作为默认值，以避免UI元素在小屏幕上被裁切。
# 用户可以根据自己的需要修改为 "1366x768x24" 或 "1920x1080x24" 等。
SCREEN_RESOLUTION="1280x960x24"

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
echo -e "${CYAN}  正在运行一键桌面脚本 - 版本: ${SCRIPT_VERSION} (${SCRIPT_DATE}) ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/6: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "lxsession"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/6: 检查并安装核心依赖...${NC}"
if ! command -v startlxde &> /dev/null; then
    echo "桌面环境未安装，正在进行安装 (这可能需要几分钟)..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install lxde-core pcmanfm xvfb x11vnc novnc websockify x11-utils -y --no-install-recommends \
        || handle_error "桌面环境或依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/6: 检查并准备Google Chrome...${NC}"
CHROME_DIR_PATH="$(pwd)/chrome-unpacked"
CHROME_EXEC_PATH="${CHROME_DIR_PATH}/opt/google/chrome/google-chrome"
if [ ! -f "${CHROME_EXEC_PATH}" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p ${CHROME_DIR_PATH} && dpkg-deb -x google-chrome.deb ${CHROME_DIR_PATH} \
        || handle_error "创建目录或解压Chrome失败。"
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- V18 新步骤: 为Chrome创建桌面快捷方式 ---
echo -e "${GREEN}>>> 步骤 3/6: 为Chrome创建桌面菜单项...${NC}"
APP_LAUNCHER_DIR="$HOME/.local/share/applications"
mkdir -p "${APP_LAUNCHER_DIR}"
CHROME_ICON_PATH="${CHROME_DIR_PATH}/opt/google/chrome/product_logo_256.png"
cat << EOF > "${APP_LAUNCHER_DIR}/google-chrome-custom.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome (Custom)
Comment=Access the Internet
Icon=${CHROME_ICON_PATH}
Exec=${CHROME_EXEC_PATH} --no-sandbox --disable-gpu
Terminal=false
Categories=Network;WebBrowser;
EOF
echo "菜单项创建成功。"

# --- V18 新步骤: 配置桌面环境（壁纸等）---
echo -e "${GREEN}>>> 步骤 4/6: 配置桌面环境...${NC}"
LXDE_CONFIG_DIR="$HOME/.config/lxsession/LXDE"
mkdir -p "${LXDE_CONFIG_DIR}"
# 让PCManFM接管桌面并设置壁纸
cat << EOF > "${LXDE_CONFIG_DIR}/autostart"
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@xscreensaver -no-splash
EOF
# 如果有默认壁纸就使用它
PCMANFM_CONFIG_DIR="$HOME/.config/pcmanfm/LXDE"
mkdir -p "${PCMANFM_CONFIG_DIR}"
if [ -f "/usr/share/lxde/wallpapers/lxde.jpg" ]; then
cat << EOF > "${PCMANFM_CONFIG_DIR}/desktop-items-0.conf"
[*]
wallpaper=/usr/share/lxde/wallpapers/lxde.jpg
wallpaper_mode=fit
desktop_bg=#000000
EOF
fi
echo "桌面配置完成。"

# --- 步骤 5: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 5/6: 正在后台启动虚拟桌面和所有服务...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM))
export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp /tmp/xvfb.auth.XXXXXX)
export XAUTHORITY=${XAUTH_FILE}

echo "  - 正在启动 Xvfb 虚拟屏幕 (${SCREEN_RESOLUTION})..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 10s bash -c "until [ -f '${XAUTHORITY}' ] && xdpyinfo >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

echo "  - 正在启动 LXDE 桌面会话..."
# V18 关键改动: 使用 lxsession 启动，确保所有配置生效
lxsession -s LXDE -e LXDE &
sleep 5

echo "  - 正在启动 x11vnc 服务器..."
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功。"

# --- 步骤 6: 启动noVNC并提供最终指引 ---
echo -e "${GREEN}>>> 步骤 6/6: 正在启动noVNC网页服务...${NC}"
if [ ! -f "${NOVNC_PATH}/vnc_auto.html" ]; then
    handle_error "noVNC 网页文件 '${NOVNC_PATH}/vnc_auto.html' 不存在！"
fi

echo -e "\n${YELLOW}======================= 远程桌面使用指南 (V18) ======================="
echo -e "一切就绪！您现在拥有一个功能完善、外观精美的远程桌面。"
echo -e "请复制并打开下面的 【完整URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【带壁纸的完整桌面】。"
echo -e "  2. 点击屏幕左下角的【开始菜单】->【互联网】->【Google Chrome (Custom)】来启动浏览器。"
echo -e "  3. '开始菜单' -> '附件' -> 'LXTerminal' 可以打开命令行终端。"
echo -e "${RED}  分辨率提示: 如果桌面显示不全或太小，请修改脚本开头的${NC}"
echo -e "${RED}             'SCREEN_RESOLUTION' 变量为您屏幕合适的尺寸 (如 '1920x1080x24')，${NC}"
echo -e "${RED}             然后重新运行此脚本。${NC}"
echo -e "${YELLOW}=======================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}

rm -f ${XAUTHORITY}
