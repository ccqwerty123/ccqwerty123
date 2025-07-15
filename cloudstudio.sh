#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V10 - 稳健启动流程)
# =================================================================
#
# 版本: 10.0
# 更新日期: 2025-07-15
#
# 特性:
# - 采用更线性和稳健的服务启动顺序。
# - 为x11vnc添加-bg参数，使其更可靠地在后台运行。
# - 增加更长的延时，确保每个服务都有足够的时间初始化。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="10.0"
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

# --- 步骤 3: 启动后台服务 (更稳健的方式) ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动虚拟桌面和所有服务...${NC}"

# 设置DISPLAY变量，供后续所有命令使用
export DISPLAY=:1

# 1. 启动虚拟屏幕，并等待它完成
echo "  - 正在启动 Xvfb 虚拟屏幕..."
Xvfb :1 -screen 0 1280x800x24 &
XVFBPID=$! # 获取Xvfb的进程ID
sleep 5 # 等待5秒，确保完全启动

# 2. 启动窗口管理器
echo "  - 正在启动 Openbox 窗口管理器..."
openbox &
sleep 2

# 3. 启动Chrome浏览器
echo "  - 正在启动 Google Chrome..."
./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu &
sleep 5 # 等待Chrome主窗口出现

# 4. 启动VNC服务器，连接到已经存在的屏幕上
echo "  - 正在启动 x11vnc 服务器..."
# -bg 参数让x11vnc更可靠地进入后台
x11vnc -display :1 -nopw -forever -bg

# 等待x11vnc初始化
sleep 3

# --- 步骤 4: 启动noVNC网页服务 (这是唯一的前台进程) ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动noVNC网页服务...${NC}"
echo "你的云环境现在应该会自动为下面的端口生成一个预览URL。"
echo "请点击那个URL来访问真正的浏览器图形界面！"

# 我们监听 8080 端口，并连接到 5901 (VNC for display :1)
websockify --web=/usr/share/novnc/ 8080 localhost:5901
