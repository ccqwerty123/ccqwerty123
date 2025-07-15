#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极脚本 (绿色版)
# =================================================================
#
# 这个脚本将彻底绕开 apt 和 snap 的限制，通过手动下载和解压的方式
# 来运行一个纯净的Google Chrome浏览器。
#
# =================================================================

# 设置颜色代码，让输出更好看
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# --- 步骤 1: 安装核心依赖 (ttyd, xorg) ---
echo -e "${GREEN}>>> 步骤 1/4: 正在安装核心依赖 (ttyd, xorg)...${NC}"
sudo apt update
sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox -y --no-install-recommends

# 检查依赖是否安装成功
if [ $? -ne 0 ]; then
    echo -e "\033[0;31m错误：核心依赖安装失败。脚本中断。${NC}"
    exit 1
fi

# --- 步骤 2: 下载 Google Chrome 的 .deb 包 ---
echo -e "${GREEN}>>> 步骤 2/4: 正在静默下载Google Chrome...${NC}"
wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

# --- 步骤 3: 手动解压 .deb 包，实现“绿色版”效果 ---
echo -e "${GREEN}>>> 步骤 3/4: 正在解压Chrome，不进行安装...${NC}"
# 创建一个目录存放解压文件
mkdir chrome-unpacked
# 使用dpkg-deb的-x参数，只提取文件，不执行安装脚本
dpkg-deb -x google-chrome.deb ./chrome-unpacked

# --- 步骤 4: 启动 ttyd 来运行我们自己解压的Chrome ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动我们自己的Chrome...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问真正的Google Chrome浏览器！"
ttyd ./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox
