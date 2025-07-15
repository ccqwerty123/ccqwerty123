#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V9 - 修正VNC端口)
# =================================================================
#
# 版本: 9.0
# 更新日期: 2025-07-15
#
# 特性:
# - 修正了websockify连接的VNC端口号 (5900 -> 5901)。
# - 这是打通整个链路的最后一步。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="9.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键Chrome脚本 - 版本: ${SCRIPT_VERSION} (${SCRIPT_DATE}) ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 清理旧进程 ---
echo -e "${GREEN}>>> 步骤 0/4: 正在清理可能存在的旧进程...${NC}"
sudo pkill -9 -f "x11vnc" >/dev/null 2>&1
sudo pkill -9 -f "websockify" >/dev/null 2>&1
sudo pkill -f "chrome" >/dev/null 2>&1
sudo pkill -f "Xvfb" >/dev/null 2>&1
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
if ! command -v x11vnc &> /dev/null; then
    echo "依赖未安装，正在进行安装..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install xorg openbox xvfb x11vnc novnc -y --no-install-recommends
else
    echo -e "${YELLOW}依赖 'x11vnc' 已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/4: 检查并准备Google Chrome...${NC}"
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    mkdir -p chrome-unpacked
    dpkg-deb -x google-chrome.deb ./chrome-unpacked
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- 步骤 3: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动虚拟桌面和Chrome...${NC}"
export DISPLAY=:1
Xvfb :1 -screen 0 1280x800x16 &
sleep 3
(
  openbox &
  ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu
) &
sleep 3
x11vnc -display :1 -nopw -forever &

# --- 步骤 4: 启动noVNC网页服务 (这是前台进程) ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动noVNC网页服务...${NC}"
echo "你的云环境现在应该会自动为下面的端口生成一个预览URL。"
echo "请点击那个URL来访问真正的浏览器图形界面！"

# 关键修复：将目标VNC端口从5900改为5901，以匹配我们创建的 :1 屏幕
websockify --web=/usr/share/novnc/ 6080 localhost:5901
