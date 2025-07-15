#!/bin/bash

# =================================================================
#  一键安装并运行完整服务器桌面的终极脚本 (V17 - LXDE 桌面)
# =================================================================
#
# 版本: 17.0
# 更新日期: 2025-07-15
#
# 特性:
# - V17 核心改进 (完整桌面环境):
#   - 新增: 安装完整的、轻量级的 LXDE 桌面环境 (lxde-core)。
#   - 移除: 替换掉简陋的 Openbox 和 xterm。
#   - 您现在将获得一个包含任务栏、开始菜单、桌面图标的熟悉桌面。
# - V16 核心改进:
#   - 移除了自动启动特定应用的行为，提供通用桌面。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="17.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc"
SCREEN_RESOLUTION="1366x768x24" # 为桌面环境使用一个更常见的宽屏分辨率

# --- 辅助函数 ---
handle_error() {
    echo -e "\n${RED}====================================================="
    echo -e "  错误: $1"
    echo -e "  脚本已终止。"
    if [ -f "/tmp/x11vnc.log" ]; then
        echo -e "  x11vnc 日志 (/tmp/x11vnc.log) 内容:"
        tail -n 10 /tmp/x11vnc.log
    fi
    echo -e "=====================================================${NC}\n"
    exit 1
}

echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键桌面脚本 - 版本: ${SCRIPT_VERSION} (${SCRIPT_DATE}) ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 终极清理 ---
echo -e "${GREEN}>>> 步骤 0/5: 正在执行终极清理...${NC}"
pkill -9 -f "x11vnc"; pkill -9 -f "websockify"; pkill -f "chrome"; pkill -f "Xvfb"; pkill -9 -f "lxsession"
echo "  - 旧进程已清理。"
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "  - 残留的锁文件和日志已清理。"
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
# V17 关键改动: 安装 lxde-core, 这是LXDE的最小化版本
if ! command -v startlxde &> /dev/null; then
    echo "桌面环境未安装，正在进行安装 (这可能需要几分钟)..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    # 我们安装 lxde-core (核心组件) 和 pcmanfm (文件管理器)
    sudo DEBIAN_FRONTEND=noninteractive apt-get install lxde-core pcmanfm xvfb x11vnc novnc websockify x11-utils x11-xserver-utils -y --no-install-recommends \
        || handle_error "桌面环境或依赖安装失败。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
echo -e "${GREEN}>>> 步骤 2/5: 检查并准备Google Chrome...${NC}"
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p chrome-unpacked && dpkg-deb -x google-chrome.deb ./chrome-unpacked \
        || handle_error "创建目录或解压Chrome失败。"
    rm google-chrome.deb
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- 步骤 3: 计算端口并设置环境变量 ---
echo -e "${GREEN}>>> 步骤 3/5: 配置环境变量...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM))
export DISPLAY=:${DISPLAY_NUM}
XAUTH_FILE=$(mktemp /tmp/xvfb.auth.XXXXXX)
export XAUTHORITY=${XAUTH_FILE}
echo "配置完成: 显示器=${DISPLAY}, VNC端口=${VNC_PORT}, 分辨率=${SCREEN_RESOLUTION}"

# --- 步骤 4: 启动后台服务 ---
echo -e "${GREEN}>>> 步骤 4/5: 正在后台启动虚拟桌面和所有服务...${NC}"
# 1. 启动虚拟屏幕
echo "  - 正在启动 Xvfb 虚拟屏幕..."
Xvfb ${DISPLAY} -screen 0 ${SCREEN_RESOLUTION} -auth ${XAUTHORITY} &
if ! timeout 10s bash -c "until [ -f '${XAUTHORITY}' ] && xdpyinfo -display ${DISPLAY} >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败。"
fi
echo "  - Xvfb 验证成功。"

# 2. V17 关键改动: 启动完整的LXDE桌面会话
echo "  - 正在启动 LXDE 桌面环境..."
startlxde &
sleep 5 # 等待桌面环境加载

# 3. 启动VNC服务器
echo "  - 正在启动 x11vnc 服务器..."
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功。"

# --- 步骤 5: 启动noVNC并提供最终指引 ---
echo -e "${GREEN}>>> 步骤 5/5: 正在启动noVNC网页服务...${NC}"
if [ ! -f "${NOVNC_PATH}/vnc_auto.html" ]; then
    handle_error "noVNC 网页文件 '${NOVNC_PATH}/vnc_auto.html' 不存在！"
fi

echo -e "\n${YELLOW}======================= 远程桌面使用指南 ======================="
echo -e "一切就绪！您现在拥有一个完整的、熟悉的远程桌面。"
echo -e "请复制并打开下面的 【完整URL】 来访问："
echo -e "${CYAN}"
echo -e "  http://<你的服务器IP或域名>:8080/vnc_auto.html?path=websockify&scaling=local"
echo -e "${NC}"
echo -e "操作说明:"
echo -e "  1. 打开链接后，您会看到一个【完整的桌面】，底部有任务栏。"
echo -e "  2. 点击屏幕左下角的【开始菜单】图标，可以找到所有程序。"
echo -e "  3. '附件' -> 'LXTerminal' 可以打开命令行终端。"
echo -e "  4. Chrome 可能不会自动出现在菜单中，您可以在终端中输入以下命令来启动它："
echo -e "     ${CYAN}$(pwd)/chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu${NC}"
echo -e "  5. 您可以像操作普通电脑一样操作这个桌面！"
echo -e "${YELLOW}==================================================================\n"

websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}

rm -f ${XAUTHORITY}
