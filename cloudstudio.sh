#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V6 - 优化参数)
# =================================================================
#
# 版本: 6.0
# 更新日期: 2025-07-15
#
# 特性:
# - 为Chrome添加优化启动参数，使其在服务器环境更稳定、更安静。
# - 继承V5的所有优点。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="6.0"
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
sudo pkill -9 -f "ttyd" >/dev/null 2>&1
sudo pkill -9 -f "chrome" >/dev/null 2>&1
sudo pkill -9 -f "Xvfb" >/dev/null 2>&1
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
if ! command -v xvfb-run &> /dev/null; then
    echo "依赖未安装，正在进行安装..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox xvfb -y --no-install-recommends
else
    echo -e "${YELLOW}依赖已安装，跳过。${NC}"
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

# --- 步骤 3: 运行！(使用Xvfb-run 和 优化参数) ---
echo -e "${GREEN}>>> 步骤 3/4: 使用Xvfb和优化参数启动Chrome...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问浏览器！"

# 定义Chrome的启动参数
CHROME_ARGS="--no-sandbox \
--disable-gpu \
--disable-dev-shm-usage \
--disable-software-rasterizer \
--disable-extensions \
--disable-sync \
--disable-background-networking \
--no-first-run \
--safebrowsing-disable-auto-update \
--password-store=basic \
--remote-debugging-port=9222"

# 运行最终的命令
ttyd xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" ./chrome-unpacked/opt/google/chrome/google-chrome $CHROME_ARGS
