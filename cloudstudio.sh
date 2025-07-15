#!/bin/bash

# =================================================================
#  一键安装运行自适应桌面的终极脚本 (V19 - 自适应分辨率与性能优化)
# =================================================================
#
# 版本: 19.0
# 更新日期: 2025-07-15
#
# 特性:
# - V19 核心改进 (体验的革命):
#   - 新增: 真正自适应分辨率！通过 noVNC 的 "resize=remote" 参数，
#     远程桌面将自动适配您本地浏览器窗口的大小，完美显示！
#   - 新增: 为 Xvfb 启用 RANDR 扩展，这是实现自适应分辨率的基础。
#   - 新增: 为 x11vnc 启用 "-ncache" 缓存选项，大幅提升流畅度，减少卡顿。
#   - 移除: 移除了不稳定的桌面美化配置，回归到LXDE最稳定默认的灰色桌面。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="19.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc"
# 这只是一个初始分辨率，连接后会自动调整
INITIAL_RESOLUTION="1024x768x24"

# --- 辅助函数 ---
handle_error() {
    echo -e "\n${RED}====================================================="
    echo -e "  错误: $1"
    echo -e "  脚本已终止。"
    if [ -f "/tmp/x11vnc.log" ]; then
        echo -e "  x11vnc 日志 (/tmp/x11vnc.log) 内容:"; tail -n 10 /tmp/x11vnc.log; fi
    echo -e "=====================================================${NC}\n"
    exit 1
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键自适应桌面脚本 - 版本: ${SCRIPT_VERSION} ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/4: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "lxsession"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/4: 检查并安装核心依赖...${NC}"
if ! command -v startlxde &> /dev/null; then
    echo "桌面环境未安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install lxde-core pcmanfm xvfb x11vnc novnc websockify x11-utils -y --no-install-recommends \
        || handle_error "桌面环境或依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/4: 检查并准备Google Chrome...${NC}"
CHROME_EXEC_PATH="$(pwd)/chrome-unpacked/opt/google/chrome/google-chrome"
if [ ! -f "${CHROME_EXEC_PATH}" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p chrome-unpacked && dpkg-deb -x google-chrome.deb ./chrome-unpacked \
        || handle_error "创建目录或解压Chrome失败。"
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- 步骤 3: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 3/4: 正在后台启动自适应虚拟桌面和所有服务...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM))
export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp /tmp/xvfb.auth.XXXXXX)
export XAUTHORITY=${XAUTH_FILE}

# V19 关键改动: 为Xvfb启用RANDR扩展，以支持动态分辨率调整
echo "  - 正在启动 Xvfb (带自适应分辨率支持)..."
Xvfb ${DISPLAY} -screen 0 ${INITIAL_RESOLUTION} -auth ${XAUTHORITY} +extension RANDR &
if ! timeout 10s bash -c "until [ -f '${XAUTHORITY}' ] && xdpyinfo >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

echo "  - 正在启动 LXDE 桌面会话..."
startlxde &
sleep 5

# V19 关键改动: 为x11vnc启用ncache性能引擎
echo "  - 正在启动 x11vnc (带性能优化)..."
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log -ncache 10

if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功。"

# --- 步骤 4: 启动noVNC并提供最终指引 ---
echo -e "${GREEN}>>> 步骤 4/4: 正在启动noVNC网页服务...${NC}"
if [ ! -f "${NOVNC_PATH}/vnc_auto.html" ]; then
    handle_error "noVNC 网页文件 '${NOVNC_PATH}/vnc_auto.html' 不存在！"
fi

echo -e "\n${YELLOW}======================= 远程桌面使用指南 (V19) ======================="
echo -e "一切就绪！这是一个【自适应】且【高性能】的远程桌面。"
echo -e "请复制并打开下面的 【终极URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&resize=remote"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，远程桌面将【自动调整】到和你浏览器窗口一样大！"
echo -e "  2. 点击左下角菜单 -> '附件' -> 'LXTerminal' 打开终端。"
echo -e "  3. 在终端中输入以下命令来启动Chrome:"
echo -e "     ${CYAN}${CHROME_EXEC_PATH} --no-sandbox --disable-gpu${NC}"
echo -e "${RED}  如何调整连接质量？${NC}"
echo -e "${RED}  1. 鼠标移动到浏览器窗口【左侧边缘中间】，会滑出一个菜单条。${NC}"
echo -e "${RED}  2. 点击齿轮图标(设置)，在 'Scaling Mode' 中选择 'Local Scaling'。${NC}"
echo -e "${RED}  3. 在 'JPEG/PNG Quality' 中可以调整图像质量来平衡清晰度和流畅度。${NC}"
echo -e "${YELLOW}=======================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}

rm -f ${XAUTHORITY}
