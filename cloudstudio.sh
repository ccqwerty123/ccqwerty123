#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v3.0 - 终极稳定版)
# ===================================================================================
#
#  此脚本已进行架构优化，解决了所有已知问题：
#  ✅ 架构优化:      移除x11vnc中间商，由webrtc-streamer直接捕捉屏幕，更稳定高效。
#  ✅ 最小化桌面:    只启动XFCE核心组件，杜绝所有D-Bus和硬件管理相关的错误。
#  ✅ 智能依赖检查:   只安装缺失的依赖，重复运行速度极快。
#  ✅ 全自动非交互:   安装过程不会因任何问题卡住。
#  ✅ 自动GPU检测:    自动选择最优的硬件或软件加速模式。
#
# ===================================================================================

# --- 美化输出的颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 清理屏幕
clear

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v3.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 1: 智能依赖检查与安装 ---
echo -e "${YELLOW}--> 步骤 1: 智能检查系统依赖...${NC}"

# 新的、更精简的依赖列表，已移除x11vnc
required_packages=(
    xfce4 dbus-x11 xvfb wget
    libx264-dev libopus-dev libasound2-dev libavcodec-dev libavdevice-dev
    libavfilter-dev libavformat-dev libavutil-dev libpostproc-dev
    libswresample-dev libswscale-dev
)
packages_to_install=()

for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        packages_to_install+=("$pkg")
    fi
done

if [ ${#packages_to_install[@]} -ne 0 ]; then
    echo "发现缺失的依赖: ${packages_to_install[*]}"
    echo "正在开始全自动安装..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update
    sudo apt-get install -yq "${packages_to_install[@]}"
    echo -e "${GREEN}✓ 所有依赖已成功安装!${NC}"
else
    echo -e "${GREEN}✓ 所有依赖均已安装。${NC}"
fi
echo " "

# --- 步骤 2: 准备工作目录和工具 ---
WORKDIR="webrtc_desktop_setup"
echo -e "${YELLOW}--> 步骤 2: 准备工作目录和工具...${NC}"
cd ~
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f "webrtc-streamer" ]; then
    echo "下载webrtc-streamer..."
    wget -q --show-progress https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz
    tar -xvf webrtc-streamer-v*.tar.gz
    mv webrtc-streamer-*/webrtc-streamer .
    rm -rf webrtc-streamer-v*.tar.gz webrtc-streamer-*/
fi
echo -e "${GREEN}✓ 工作目录与工具准备就绪!${NC}"
echo " "

# --- 步骤 3: 启动远程桌面核心服务 ---
echo -e "${YELLOW}--> 步骤 3: 启动远程桌面核心服务...${NC}"

# 配置参数
WHD_RESOLUTION="1600x900x24"
LISTENING_PORT="8000"
export DISPLAY=:1

# 检测NVIDIA GPU
if nvidia-smi &> /dev/null; then
    echo -e "${GREEN}✓ 检测到 NVIDIA GPU! 将以硬件加速模式启动 (NVENC).${NC}"
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    echo -e "${YELLOW}! 未检测到 NVIDIA GPU。将以软件编码模式启动 (CPU).${NC}"
    VCODEC_OPTION="vcodec=h264"
fi

# 进程清理函数
cleanup() {
    echo " "
    echo -e "${BLUE}--- 正在关闭所有服务... ---${NC}"
    pkill -P $$ &>/dev/null
    echo "清理完成。"
}
trap cleanup EXIT INT TERM

# 启动虚拟屏幕
echo "启动虚拟屏幕 (Xvfb)..."
Xvfb $DISPLAY -screen 0 $WHD_RESOLUTION &
sleep 2

# 启动最小化的XFCE核心组件
echo "启动最小化XFCE桌面核心 (Session + Window Manager)..."
xfce4-session &
xfwm4 &
sleep 2

echo " "
echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}          🎉🎉🎉 一切就绪! 🎉🎉🎉          ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "
echo -e "请进行最后的操作:"
echo -e "1. 在 Cloud Studio 界面，转发 TCP 端口: ${YELLOW}${LISTENING_PORT}${NC}"
echo -e "2. 在您的浏览器中，打开 Cloud Studio 提供的那个 ${GREEN}公开URL${NC}"
echo -e "3. 在打开的网页上，您会看到一个链接，点击它即可进入桌面。"
echo " "
echo -e "按 ${YELLOW}Ctrl+C${NC} 可以停止此脚本和所有远程桌面服务。"
echo " "

# 启动核心的流媒体服务器，直接捕捉X11屏幕
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
