#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V5 - Xvfb方案)
# =================================================================
#
# 版本: 5.0
# 更新日期: 2025-07-15
#
# 特性:
# - 增加版本号和时间戳显示，确认脚本已更新。
# - 使用Xvfb创建虚拟屏幕，彻底解决 $DISPLAY 错误。
# - 自动清理旧进程，可重复运行。
# - 按需安装依赖，按需下载Chrome。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="5.0"
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

# --- 步骤 1: 安装所有依赖 (包括Xvfb) ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
# 检查xvfb是否存在，如果不存在，则安装所有依赖
if ! command -v xvfb-run &> /dev/null; then
    echo "依赖未安装，正在进行安装 (ttyd, xorg, openbox, xvfb)..."
    sudo apt update
    # xvfb包含在xvfb包里，它会自动处理好X11的依赖
    sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox xvfb -y --no-install-recommends
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31m错误：核心依赖安装失败。脚本中断。${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}依赖已安装，跳过此步骤。${NC}"
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

# --- 步骤 3: 运行！(使用Xvfb-run) ---
echo -e "${GREEN}>>> 步骤 3/4: 使用Xvfb启动我们自己的Chrome...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问真正的Google Chrome浏览器！"

# xvfb-run 是一个神奇的包装命令。
# 它会自动在后台启动一个Xvfb虚拟屏幕，设置好DISPLAY环境变量，
# 然后再执行我们指定的命令。当主命令结束后，它还会自动清理Xvfb进程。
ttyd xvfb-run --auto-servernum --server-args="-screen 0 1280x800x24" ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox
