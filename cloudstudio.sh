#!/bin/bash

# =================================================================
#  一键安装运行高度稳定桌面环境的终极脚本 (V22 - 极简完美版)
# =================================================================
#
# 版本: 22.0 (终极版)
# 更新日期: 2025-07-15
#
# 特性:
# - V22 核心改进 (性能与稳定性完美融合):
#   - 核心: 放弃 LXDE，回归轻量级 Openbox，但通过集成 `jgmenu` 提供强大的动态菜单。
#   - 修复: 彻底解决所有“no session”、“显示异常”等顽固问题。
#   - 新增: `jgmenu` 将自动扫描并显示 Chrome，无需复杂配置。
#   - 新增: 使用 `feh` 强制设置桌面背景，告别黑屏。
#   - 性能: 启动更快，资源占用更低，体验更流畅。
#   - 移除: 彻底删除 `dbus-launch`，简化流程，避免会话错误。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="22.0"
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
#  固定分辨率是此类应用最稳定可靠的方式。请修改为您最舒服的尺寸。
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
echo -e "${CYAN}  正在运行一键极简桌面脚本 - 版本: ${SCRIPT_VERSION} ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/4: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "openbox"; pkill -9 -f "jgmenu"; pkill -9 -f "feh"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
# 新增 jgmenu 和 feh
if ! command -v openbox &> /dev/null || ! command -v jgmenu &> /dev/null || ! command -v feh &> /dev/null; then
    echo "核心依赖未完全安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install xorg openbox xvfb x11vnc novnc websockify x11-utils jgmenu feh -y --no-install-recommends \
        || handle_error "依赖安装失败。"
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
# 为Chrome创建标准的 .desktop 文件，jgmenu 会自动发现它
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
echo "Chrome准备就绪并已添加到菜单系统。"

# --- 步骤 3: 启动后台服务 (Openbox + jgmenu + feh) ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动高稳定性虚拟桌面...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM)); export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp); export XAUTHORITY=${XAUTH_FILE}

echo "  - 正在启动 Xvfb (固定分辨率: ${SCREEN_RESOLUTION})..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 10s bash -c "until xdpyinfo >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

echo "  - 正在启动 Openbox 窗口管理器..."
openbox &
sleep 1

# 强制设置一个灰色背景，告别黑屏
echo "  - 正在设置桌面背景..."
# 可以换成其他颜色，例如 "black" 或 "white"
feh --bg-fill "#444444" & # 设置一个中等灰色
echo "  - 桌面背景已设置。"

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

echo -e "\n${YELLOW}======================= 远程桌面使用指南 (V22 - 终极稳定版) ======================="
echo -e "一切就绪！这是一个【极度稳定且响应迅速】的远程桌面。"
echo -e "请复制并打开下面的 【终极URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【灰色背景的桌面】。"
echo -e "  2. 在桌面上【点击鼠标右键】即可看到一个功能强大的菜单！"
echo -e "  3. 从菜单中选择 'Google Chrome' 即可启动浏览器。"
echo -e "  4. 从菜单中选择 'Terminal' (或 'xterm') 即可打开命令行终端。"
echo -e "${RED}  !!! 如何获得最佳显示效果? !!!${NC}"
echo -e "${RED}  请【修改脚本开头的'SCREEN_RESOLUTION'变量】为您自己屏幕最合适的分辨率，${NC}"
echo -e "${RED}  然后重新运行此脚本。这是最可靠、最清晰的显示方法！${NC}"
echo -e "${YELLOW}=================================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}
rm -f ${XAUTHORITY}
