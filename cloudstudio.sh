#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V3)
# =================================================================
#
# 特性:
# - 自动杀死旧的ttyd和Chrome进程，防止端口占用。
# - 判断依赖是否已安装，避免重复下载和安装。
# - 通过手动下载和解压的方式运行纯净的Google Chrome。
#
# =================================================================

# 设置颜色代码
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 步骤 0: 清理旧进程 ---
echo -e "${GREEN}>>> 步骤 0/5: 正在清理可能存在的旧进程...${NC}"
# 使用pkill命令，它可以根据进程名直接杀死进程，更方便
# -f 参数表示匹配完整的命令行
# @ 符号忽略错误输出，防止在没有进程可杀时显示错误信息
sudo pkill -9 -f "ttyd" >/dev/null 2>&1
sudo pkill -9 -f "chrome" >/dev/null 2>&1
echo "清理完成。"

# --- 步骤 1: 安装核心依赖 (ttyd, xorg, etc.) ---
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
# 检查ttyd是否存在，如果不存在，再执行安装
if ! command -v ttyd &> /dev/null
then
    echo "ttyd 未安装，正在进行安装..."
    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox -y --no-install-recommends
    # 检查依赖是否安装成功
    if [ $? -ne 0 ]; then
        echo -e "\033[0;31m错误：核心依赖安装失败。脚本中断。${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}依赖已安装，跳过此步骤。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/5: 检查并准备Google Chrome...${NC}"
# 检查我们自己解压的Chrome程序是否存在
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    
    # 下载 .deb 包
    echo "  - 正在静默下载Google Chrome..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    
    # 解压 .deb 包
    echo "  - 正在解压Chrome，不进行安装..."
    mkdir -p chrome-unpacked
    dpkg-deb -x google-chrome.deb ./chrome-unpacked
    
    # 清理下载的.deb文件，保持整洁
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过下载和解压。${NC}"
fi

# --- 步骤 3: 运行！---
echo -e "${GREEN}>>> 步骤 3/5: 正在启动我们自己的Chrome...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问真正的Google Chrome浏览器！"
ttyd ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox
