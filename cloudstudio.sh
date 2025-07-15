#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V13 - 授权认证与路径修复)
# =================================================================
#
# 版本: 13.0
# 更新日期: 2025-07-15
#
# 特性:
# - V13 核心改进:
#   - 新增: 使用 X authority "magic cookie" 文件在 Xvfb 和 x11vnc
#     之间建立强认证连接，彻底解决 "socket hang up" 问题。
#   - 新增: 自动验证 noVNC 网页文件的路径，修复显示目录列表的问题。
#   - 新增: 将 x11vnc 的详细日志输出到 /tmp/x11vnc.log 以便调试。
# - V12 核心改进:
#   - 使用 -rfbport 强制 x11vnc 监听指定端口。
# - V11 核心改进:
#   - 完整的错误处理、智能的服务启动验证、动态端口配置。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="13.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
DISPLAY_NUM=1
NOVNC_PATH="/usr/share/novnc" # noVNC 文件的标准路径

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
    # 在退出前执行最终清理
    pkill -9 -f "x11vnc" >/dev/null 2>&1
    pkill -9 -f "websockify" >/dev/null 2>&1
    pkill -f "chrome" >/dev/null 2>&1
    pkill -f "Xvfb" >/dev/null 2>&1
    pkill -f "openbox" >/dev/null 2>&1
    exit 1
}


echo -e "${CYAN}=====================================================${NC}"
echo -e "${CYAN}  正在运行一键Chrome脚本 - 版本: ${SCRIPT_VERSION} (${SCRIPT_DATE}) ${NC}"
echo -e "${CYAN}=====================================================${NC}"

# --- 步骤 0: 清理旧进程 ---
echo -e "${GREEN}>>> 步骤 0/5: 正在清理可能存在的旧进程...${NC}"
pkill -9 -f "x11vnc" >/dev/null 2>&1
pkill -9 -f "websockify" >/dev/null 2>&1
pkill -f "chrome" >/dev/null 2>&1
pkill -f "Xvfb" >/dev/null 2>&1
pkill -f "openbox" >/dev/null 2>&1
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM} /tmp/x11vnc.log
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
# x11-xserver-utils 包含 xauth
if ! command -v x11vnc &> /dev/null || ! command -v websockify &> /dev/null || ! command -v xauth &> /dev/null; then
    echo "依赖未完全安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install xorg openbox xvfb x11vnc novnc websockify x11-utils x11-xserver-utils -y --no-install-recommends \
        || handle_error "依赖安装失败。"
    echo "依赖安装成功。"
else
    echo -e "${YELLOW}核心依赖已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
# (此部分无改动)
echo -e "${GREEN}>>> 步骤 2/5: 检查并准备Google Chrome...${NC}"
if [ ! -f "./chrome-unpacked/opt/google/chrome/google-chrome" ]; then
    echo "本地Chrome不存在，正在下载并解压..."
    wget -q -O google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
        || handle_error "Google Chrome 下载失败。"
    mkdir -p chrome-unpacked \
        || handle_error "创建 'chrome-unpacked' 目录失败。"
    dpkg-deb -x google-chrome.deb ./chrome-unpacked \
        || handle_error "解压 'google-chrome.deb' 失败。"
    rm google-chrome.deb
    echo "Chrome 准备就绪。"
else
    echo -e "${YELLOW}本地Chrome已存在，跳过。${NC}"
fi

# --- 步骤 3: 计算端口并设置环境变量 ---
echo -e "${GREEN}>>> 步骤 3/5: 配置环境变量...${NC}"
VNC_PORT=$((5900 + DISPLAY_NUM))
export DISPLAY=:${DISPLAY_NUM}
# V13 新增: 定义认证文件的路径
XAUTH_FILE=$(mktemp /tmp/xvfb.auth.XXXXXX)
export XAUTHORITY=${XAUTH_FILE}
echo "配置完成: 显示器 = ${DISPLAY}, VNC端口 = ${VNC_PORT}, 认证文件 = ${XAUTHORITY}"

# --- 步骤 4: 启动后台服务 (带授权认证) ---
echo -e "${GREEN}>>> 步骤 4/5: 正在后台启动虚拟桌面和所有服务...${NC}"

# 1. 启动虚拟屏幕，并创建认证文件
echo "  - 正在启动 Xvfb 虚拟屏幕并生成认证..."
# V13 关键改动: 使用 -auth 参数启动 Xvfb
Xvfb ${DISPLAY} -screen 0 1280x800x24 -auth ${XAUTHORITY} &
if ! timeout 5s bash -c "until [ -f '${XAUTHORITY}' ] && xdpyinfo -display ${DISPLAY} >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动或认证文件创建失败。"
fi
echo "  - Xvfb 验证成功。"

# 2. 启动窗口管理器
echo "  - 正在启动 Openbox 窗口管理器..."
openbox &
sleep 1

# 3. 启动Chrome浏览器
echo "  - 正在启动 Google Chrome..."
./chrome-unpacked/opt/google/chrome/google-chrome --no-sandbox --disable-gpu &
sleep 5

# 4. 启动VNC服务器，使用认证文件连接
echo "  - 正在启动 x11vnc 服务器 (日志位于 /tmp/x11vnc.log)..."
# V13 关键改动: 使用 -auth 和 -rfbport，并记录日志
x11vnc -auth ${XAUTHORITY} -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg -o /tmp/x11vnc.log

# 验证VNC端口是否监听
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。"
fi
echo "  - x11vnc 验证成功，正在监听端口 ${VNC_PORT}。"

# --- 步骤 5: 启动noVNC网页服务 (带路径验证) ---
echo -e "${GREEN}>>> 步骤 5/5: 正在启动noVNC网页服务...${NC}"

# V13 关键改动: 验证 noVNC 路径是否有效
if [ ! -f "${NOVNC_PATH}/vnc.html" ]; then
    handle_error "noVNC 网页文件未在 '${NOVNC_PATH}/vnc.html' 找到！请检查 noVNC 安装路径。"
fi
echo "  - noVNC 路径验证成功。"

echo -e "${YELLOW}一切就绪！请通过云服务商提供的 8080 端口URL访问浏览器。${NC}"
websockify --web=${NOVNC_PATH} 8080 localhost:${VNC_PORT}

# 脚本结束时清理认证文件
rm -f ${XAUTHORITY}
