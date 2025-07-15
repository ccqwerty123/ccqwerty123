#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V8 - noVNC方案)
# =================================================================
#
# 版本: 8.0
# 更新日期: 2025-07-15
#
# 特性:
# - 使用最稳定可靠的 Xvfb + x11vnc + noVNC 方案。
# - noVNC直接提供图形界面，不再是后台日志。
# - 继承了版本检查、进程清理、按需安装等所有优点。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="8.0"
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
# 检查 x11vnc 是否存在
if ! command -v x11vnc &> /dev/null; then
    echo "依赖未安装，正在进行安装 (xorg, openbox, xvfb, x11vnc, novnc)..."
    sudo apt update
    # novnc 和 websockify (noVNC的桥接工具) 包含在novnc包里
    sudo DEBIAN_FRONTEND=noninteractive apt install xorg openbox xvfb x11vnc novnc -y --no-install-recommends
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31m错误：核心依赖安装失败。脚本中断。${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}依赖 'x11vnc' 已安装，跳过安装步骤。${NC}"
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
    echo -e "${YELLOW}本地Chrome已存在，跳过下载和解压。${NC}"
fi

# --- 步骤 3: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动虚拟桌面和Chrome...${NC}"

# 在后台启动一个1280x800的虚拟屏幕，编号为 :1
export DISPLAY=:1
Xvfb :1 -screen 0 1280x800x16 &

# 等待Xvfb启动
sleep 3

# 在虚拟屏幕上启动窗口管理器和Chrome
(
  openbox &
  ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu
) &

# 等待Chrome启动
sleep 3

# 在后台启动x11vnc，把虚拟屏幕:1的内容用VNC协议分享出来
x11vnc -display :1 -nopw -forever &

# --- 步骤 4: 启动noVNC网页服务 (这是前台进程) ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动noVNC网页服务...${NC}"
echo "你的云环境现在应该会自动为下面的端口生成一个预览URL。"
echo "请点击那个URL来访问真正的浏览器图形界面！"

# 启动websockify，它会把noVNC的网页和VNC服务桥接起来
# 它会监听 6080 端口，并把请求转发给本地的VNC服务(5900)
websockify --web=/usr/share/novnc/ 6080 localhost:5900
