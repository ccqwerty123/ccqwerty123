#!/bin/bash

# =================================================================
#  一键安装并运行Google Chrome的终极健壮脚本 (V12 - 强制端口绑定)
# =================================================================
#
# 版本: 12.0
# 更新日期: 2025-07-15
#
# 特性:
# - V12 核心改进:
#   - 新增: 为 x11vnc 使用 -rfbport 参数，强制其监听指定端口，
#     避免其自动扫描并连接到错误的显示器 (如 :0)。
#   - 这是解决 v11 中遇到的 x11vnc 端口不匹配问题的最终方案。
# - V11 核心改进:
#   - 新增: 完整的错误处理机制，任何关键步骤失败则立即退出。
#   - 新增: 智能的服务启动验证，取代固定的延时等待。
#   - 新增: 动态端口配置，只需修改一处即可更改所有端口。
#
# =================================================================

# --- 脚本元数据和颜色代码 ---
SCRIPT_VERSION="12.0"
SCRIPT_DATE="2025-07-15"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

# --- 核心配置 ---
# 在这里定义显示器编号，所有后续命令将自动使用它。
DISPLAY_NUM=1


# --- 辅助函数 ---
# 统一的错误处理函数
handle_error() {
    echo -e "\n${RED}====================================================="
    echo -e "  错误: $1"
    echo -e "  脚本已终止。"
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
echo "清理完成。"

# --- 步骤 1: 安装所有依赖 ---
echo -e "${GREEN}>>> 步骤 1/5: 检查并安装核心依赖...${NC}"
if ! command -v x11vnc &> /dev/null || ! command -v websockify &> /dev/null; then
    echo "依赖未完全安装，正在进行安装..."
    sudo apt-get update || handle_error "apt-get update 失败。请检查您的软件源设置。"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install xorg openbox xvfb x11vnc novnc websockify x11-utils -y --no-install-recommends \
        || handle_error "依赖安装失败。请检查apt日志。"
    echo "依赖安装成功。"
else
    echo -e "${YELLOW}核心依赖 'x11vnc' 和 'websockify' 已安装，跳过。${NC}"
fi

# --- 步骤 2: 准备 Google Chrome ---
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
echo "配置完成: 显示器 = ${DISPLAY}, VNC端口 = ${VNC_PORT}"

# --- 步骤 4: 启动后台服务 (带启动验证) ---
echo -e "${GREEN}>>> 步骤 4/5: 正在后台启动虚拟桌面和所有服务...${NC}"

# 1. 启动虚拟屏幕，并验证它是否成功
echo "  - 正在启动 Xvfb 虚拟屏幕..."
Xvfb ${DISPLAY} -screen 0 1280x800x24 &
if ! timeout 5s bash -c "until xdpyinfo -display ${DISPLAY} >/dev/null 2>&1; do sleep 0.1; done"; then
    handle_error "Xvfb 虚拟屏幕启动失败或无响应。"
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

# 4. 启动VNC服务器，并强制指定端口
echo "  - 正在启动 x11vnc 服务器..."
# V12 关键改动: 使用 -rfbport 强制指定VNC端口，避免自动选择错误端口。
x11vnc -display ${DISPLAY} -rfbport ${VNC_PORT} -nopw -forever -bg

# 等待最多5秒，验证VNC端口是否被监听
if ! timeout 5s bash -c "until ss -tln | grep -q ':${VNC_PORT}'; do sleep 0.1; done"; then
    handle_error "x11vnc 未能成功监听端口 ${VNC_PORT}。可能是 ${DISPLAY} 不存在或已被占用。"
fi
echo "  - x11vnc 验证成功，正在监听端口 ${VNC_PORT}。"

# --- 步骤 5: 启动noVNC网页服务 (前台进程) ---
echo -e "${GREEN}>>> 步骤 5/5: 正在启动noVNC网页服务...${NC}"
echo -e "${YELLOW}你的云环境现在应该会自动为下面的端口生成一个预览URL。${NC}"
echo -e "${YELLOW}请点击该URL来访问真正的浏览器图形界面！${NC}"

websockify --web=/usr/share/novnc/ 8080 localhost:${VNC_PORT}
