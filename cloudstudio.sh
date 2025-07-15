#!/bin/bash

# =================================================================
#  一键安装并运行 Chromium 浏览器的脚本
# =================================================================
#
# 这个脚本会自动完成以下任务:
# 1. 更新系统的软件包列表。
# 2. 以非交互的“静默模式”安装 ttyd 和其他图形依赖。
# 3. 尝试安装 apt 版的 Chromium（即使它可能是一个snap引导包）。
# 4. 最终启动 ttyd 来运行 Chromium。
#
# =================================================================

# 设置颜色代码，让输出更好看
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# 步骤 1: 更新软件包列表
echo -e "${GREEN}>>> 步骤 1/3: 正在更新软件包列表...${NC}"
sudo apt update

# 步骤 2: 以非交互模式安装所有依赖
# 我们一次性把所有需要的包都放进去
echo -e "${GREEN}>>> 步骤 2/3: 正在安装 ttyd, xorg, openbox 和 chromium-browser...${NC}"
sudo DEBIAN_FRONTEND=noninteractive apt install ttyd xorg openbox chromium-browser -y --no-install-recommends

# 检查上一步是否成功
if [ $? -ne 0 ]; then
    echo -e "\033[0;31m错误：依赖安装失败。脚本中断。${NC}"
    exit 1
fi

# 步骤 3: 启动 ttyd 来运行 Chromium
echo -e "${GREEN}>>> 步骤 3/3: 正在启动 Chromium...${NC}"
echo "你的云环境现在应该会自动生成一个预览URL。"
echo "请点击那个URL来访问Chromium浏览器。"
ttyd chromium-browser --no-sandbox
