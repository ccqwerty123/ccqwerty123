#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V4 - 尝试修复DISPLAY)
# =================================================================
#
# 特性:
# - 在启动Chrome前，先在后台启动一个X Server。
# - 手动为Chrome设置DISPLAY环境变量。
#
# =================================================================

# 颜色和清理部分保持不变
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}>>> 步骤 0/5: 正在清理可能存在的旧进程...${NC}"
sudo pkill -9 -f "ttyd" >/dev/null 2>&1
sudo pkill -9 -f "chrome" >/dev/null 2>&1
sudo pkill -9 -f "Xorg" >/dev/null 2>&1
echo "清理完成。"

# 依赖安装部分保持不变
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
if ! command -v ttyd &> /dev/null; then
    echo "依赖未安装，正在进行安装..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox -y --no-install-recommends
else
    echo -e "${YELLOW}依赖已安装，跳过。${NC}"
fi

# Chrome准备部分保持不变
echo -e "${GREEN}>>> 步骤 2/5: 检查并准备Google Chrome...${NC}"
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    mkdir -p chrome-unpacked
    dpkg-deb -x google-chrome.deb ./chrome-unpacked
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- 关键的修复步骤 ---
echo -e "${GREEN}>>> 步骤 3/5: 在后台启动一个虚拟X Server...${NC}"
# 使用 startx 在后台启动一个基本的X环境，并将所有输出重定向到日志文件
# `&` 符号让它在后台运行
startx > /tmp/x-server.log 2>&1 &
# 等待几秒钟，确保X Server有足够的时间启动
sleep 5

# --- 步骤 4: 运行！---
echo -e "${GREEN}>>> 步骤 4/5: 正在启动我们自己的Chrome...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问真正的Google Chrome浏览器！"
# 在运行Chrome前，手动指定DISPLAY变量
ttyd env DISPLAY=:0 ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox
