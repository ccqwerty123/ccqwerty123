#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V16 - 完整桌面体验)
# =================================================================
#
# 版本: 16.0
# 更新日期: 2025-07-15
#
# 特性:
# - V16 核心改进 (完整桌面):
#   - 新增: 安装轻量级终端 xterm。
#   - 新增: 动态创建 Openbox 右键菜单，允许随时启动终端和Chrome。
#   - 移除: 不再自动启动 Chrome，而是提供一个干净的桌面环境。
#   - 您现在拥有一个可以通过浏览器操作的、完整的远程服务器桌面。
# - V15 核心改进 (用户体验):
#   - 使用 vnc_auto.html 和 scaling=local 实现自动连接和缩放。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="16.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc"
SCREEN_RESOLUTION="1280x800x24"

# --- 辅助函数 ---
handle_error() {
    echo -e "\n${RED}====================================================="
    echo -e "  错误: $1"
    echo -e "  脚本已终止。"
    if [ -f "/tmp/x11vnc.log" ]; then
        echo -e "  x11vnc 日志 (/tmp/x11vnc.log) 内容:"
        tail -n 10 /tmp/x11vnc.log
    fi
    echo -e "=====================================================${NC}\n"
    exit 1
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键脚本 - 版本: ${SCRIPT_VERSION} (${SCRIPT_DATE}) ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/6: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -f "openbox"
echo "  - 旧进程已清理。"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "  - 残留的锁文件和日志已清理。"
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/6: 检查并安装核心依赖...${NC}"
# V16 关键改动: 增加 xterm
if ! command -v x11vnc &> /dev/null || ! command -v websockify &> /dev/null || ! command -v xauth &> /dev/null || ! command -v xterm &> /dev/null; then
    echo "依赖未完全安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install xorg openbox xvfb x11vnc novnc websockify x11-utils x11-xserver-utils xterm -y --no-install-recommends \
        || handle_error "依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/6: 检查并准备Google Chrome...${NC}"
# (此部分无改动)
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p chrome-unpacked && dpkg-deb -x google-chrome.deb ./chrome-unpacked \
        || handle_error "创建目录或解压Chrome失败。"
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- V16 新步骤: 配置Openbox右键菜单 ---
echo -e "${GREEN}>>> 步骤 3/6: 配置桌面右键菜单...${NC}"
mkdir -p ~/.config/openbox
cat << 'EOF' > ~/.config/openbox/menu.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/menus">
<menu id="root-menu" label="Openbox 3">
  <item label="Terminal">
    <action name="Execute"><execute>xterm</execute></action>
  </item>
  <item label="Google Chrome">
    <action name="Execute"><execute>/app/chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu</execute></action>
  </item>
  <separator/>
  <item label="Exit">
    <action name="Exit"/>
  </item>
</menu>
</openbox_menu>
EOF
# 注意: 上面的Chrome路径 /app/ 是一个常见云IDE的路径，如果您的脚本不在/app/下运行，请修改为绝对路径或相对路径。
# 为了通用性，我们动态替换为当前工作目录的路径。
CHROME_PATH="$(pwd)/chrome-unpacked/opt/google/chrome/google-chrome"
sed -i "s|/app/chrome-unpacked/opt/google/chrome/google-chrome|${CHROME_PATH}|" ~/.config/openbox/menu.xml
echo "右键菜单配置完成。"


# --- 步骤 4: 计算端口并设置环境变量 ---
echo -e "${GREEN}>>> 步骤 4/6: 配置环境变量...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM))
export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp /tmp/xvfb.auth.XXXXXX)
export XAUTHORITY=${XAUTH_FILE}
echo "配置完成: 显示器=${DISPLAY}, VNC端口=${VNC_PORT}, 分辨率=${SCREEN_RESOLUTION}"

# --- 步骤 5: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 5/6: 正在后台启动虚拟桌面和所有服务...${NC}"
# 1. 启动虚拟屏幕
echo "  - 正在启动 Xvfb 虚拟屏幕..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 5s bash -c "until [ -f '${XAUTHORITY}' ] && xdpyinfo -display ${DISPLAY} >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

# 2. 启动窗口管理器
echo "  - 正在启动 Openbox 窗口管理器..."
openbox &
sleep 1

# 3. V16 关键改动: 不再自动启动Chrome
# echo "  - 正在启动 Google Chrome (强制最大化)..."
# ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu --start-maximized &
# sleep 5

# 4. 启动VNC服务器
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

echo -e "\n${YELLOW}======================= 远程桌面使用指南 ======================="
echo -e "一切就绪！您现在拥有一个完整的远程桌面。"
echo -e "请复制并打开下面的 【完整URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【空白的灰色桌面】。这是正常的！"
echo -e "  2. 在灰色区域【点击鼠标右键】，会弹出一个菜单。"
echo -e "  3. 从菜单中选择 'Terminal' 来打开一个命令行终端。"
echo -e "  4. 从菜单中选择 'Google Chrome' 来启动浏览器。"
echo -e "  5. 您可以在终端里运行任何Linux命令来操作服务器。"
echo -e "${YELLOW}==================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}

rm -f ${XAUTHORITY}
