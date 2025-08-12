#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v2.0 - 智能优化版)
# ===================================================================================
#
#  此脚本已优化，具备以下特性：
#  ✅ 智能依赖检查:   只安装缺失的依赖，重复运行速度极快。
#  ✅ 全自动非交互:   安装过程不会因键盘布局等问题卡住。
#  ✅ 增量式工具下载:   如果工具已存在，则跳过下载。
#  ✅ 自动GPU检测:    自动选择最优的硬件或软件加速模式。
#
# ===================================================================================

# --- 脚本设置 ---
# set -e: 如果任何命令失败，脚本将立即退出，保证安全性。
set -e

# --- 美化输出的颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 清理屏幕，提供一个干净的开始
clear

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  🚀 启动 Cloud Studio 智能远程桌面部署 (v2.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 1: 智能依赖检查与安装 ---
echo -e "${YELLOW}--> 步骤 1: 正在智能检查系统依赖...${NC}"

# 定义所有需要的依赖包
required_packages=(
    xfce4 dbus-x11 xvfb x11vnc wget
    libx264-dev libopus-dev libasound2-dev libavcodec-dev libavdevice-dev
    libavfilter-dev libavformat-dev libavutil-dev libpostproc-dev
    libswresample-dev libswscale-dev
)

# 创建一个数组来存放需要安装的包
packages_to_install=()

# 循环检查每个包是否已安装
for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        packages_to_install+=("$pkg")
    fi
done

# 如果有需要安装的包，则执行安装
if [ ${#packages_to_install[@]} -ne 0 ]; then
    echo "发现缺失的依赖: ${packages_to_install[*]}"
    echo "正在开始安装，此过程将全自动进行..."
    
    # 设置为非交互模式，避免提问
    export DEBIAN_FRONTEND=noninteractive
    
    sudo apt-get update
    sudo apt-get install -yq "${packages_to_install[@]}"
    
    echo -e "${GREEN}✓ 所有依赖已成功安装!${NC}"
else
    echo -e "${GREEN}✓ 所有依赖均已安装，无需操作。${NC}"
fi
echo " "

# --- 步骤 2: 创建并进入工作目录 ---
WORKDIR="webrtc_desktop_setup"
echo -e "${YELLOW}--> 步骤 2: 设置工作目录: ~/${WORKDIR}${NC}"
cd ~
# 如果目录不存在，则创建
mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo -e "${GREEN}✓ 工作目录准备就绪!${NC}"
echo " "

# --- 步骤 3: 增量式下载工具 ---
echo -e "${YELLOW}--> 步骤 3: 检查并准备 WebRTC 流媒体服务器...${NC}"

if [ ! -f "webrtc-streamer" ]; then
    echo "未发现工具，正在下载..."
    wget -q --show-progress https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz
    tar -xvf webrtc-streamer-v*.tar.gz
    mv webrtc-streamer-*/webrtc-streamer .
    # 清理下载的压缩包和空目录
    rm -rf webrtc-streamer-v*.tar.gz webrtc-streamer-*/
    echo -e "${GREEN}✓ 工具下载并准备就绪!${NC}"
else
    echo -e "${GREEN}✓ 工具已存在，无需下载。${NC}"
fi
echo " "


# --- 步骤 4: 启动远程桌面服务 ---
echo -e "${YELLOW}--> 步骤 4: 启动远程桌面服务...${NC}"

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

# 启动各项服务
echo "启动虚拟屏幕 (Xvfb)..."
Xvfb $DISPLAY -screen 0 $WHD_RESOLUTION &
sleep 2

echo "启动XFCE桌面环境..."
startxfce4 &
sleep 2

echo "启动x11vnc屏幕捕捉源..."
x11vnc -display $DISPLAY -nopw -quiet -forever &
sleep 1

echo " "
echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}          🎉🎉🎉 一切就绪! 🎉🎉🎉          ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "
echo -e "请进行最后的操作:"
echo -e "1. 在 Cloud Studio 界面，转发 TCP 端口: ${YELLOW}${LISTENING_PORT}${NC}"
echo -e "2. 在您的浏览器中，打开 Cloud Studio 提供的那个 ${GREEN}公开URL${NC}"
echo " "
echo -e "按 ${YELLOW}Ctrl+C${NC} 可以停止此脚本和所有远程桌面服务。"
echo " "

# 根据检测结果，启动核心的流媒体服务器
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "vnc://localhost${DISPLAY}?${VCODEC_OPTION}"
