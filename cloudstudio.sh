#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v6.0 - “外科手术”版)
# ===================================================================================
#
#  此版本为最终解决方案，针对高限制环境设计，具备以下特性：
#  ✅ 精准清场:       通过 lsof 命令精确找到并强制结束占用物理屏幕(:0)的任何进程。
#  ✅ 占领主屏:       不再创建虚拟屏幕，直接接管并使用性能最好的物理屏幕 :0。
#  ✅ 绝对通用:       无需关心环境中预装了什么程序，找到占用者就清理。
#  ✅ 稳定可靠:       保留所有智能依赖检查、非交互式安装、GPU检测等优点。
#
# ===================================================================================

# --- 美化输出的颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v6.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 1: 智能依赖检查与安装 ---
echo -e "${YELLOW}--> 步骤 1: 智能检查系统依赖 (包含lsof)...${NC}"
required_packages=(lsof xfce4 dbus-x11 wget libx264-dev libopus-dev libasound2-dev libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev libavutil-dev libpostproc-dev libswresample-dev libswscale-dev)
packages_to_install=()
for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        packages_to_install+=("$pkg")
    fi
done
if [ ${#packages_to_install[@]} -ne 0 ]; then
    echo "发现缺失的依赖，正在全自动安装..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update && sudo apt-get install -yq "${packages_to_install[@]}"
    echo -e "${GREEN}✓ 所有依赖已成功安装!${NC}"
else
    echo -e "${GREEN}✓ 所有依赖均已安装。${NC}"
fi
echo " "

# --- 步骤 2: 精确清理物理屏幕 :0 ---
# /tmp/.X11-unix/X0 是 DISPLAY=:0 的套接字文件
X0_SOCKET="/tmp/.X11-unix/X0"
echo -e "${YELLOW}--> 步骤 2: 正在检查并清理物理屏幕 :0 ...${NC}"
if [ -S "$X0_SOCKET" ]; then
    # 使用 lsof 找到所有正在使用这个套接字的进程PID
    PIDS_TO_KILL=$(sudo lsof -t "$X0_SOCKET" 2>/dev/null)
    if [ -n "$PIDS_TO_KILL" ]; then
        echo -e "发现以下进程正在占用屏幕:0，将强制结束它们:\n${PIDS_TO_KILL}"
        # 使用 xargs 和 kill -9 确保所有找到的进程都被杀死
        echo "$PIDS_TO_KILL" | xargs sudo kill -9
        sleep 2 # 等待进程完全退出
        echo -e "${GREEN}✓ 屏幕 :0 已被成功清理!${NC}"
    else
        echo -e "${GREEN}✓ 屏幕 :0 是干净的，无需清理。${NC}"
    fi
else
    echo -e "${GREEN}✓ 未发现活动的屏幕 :0，将创建新的。${NC}"
fi
echo " "


# --- 步骤 3: 准备工作目录和工具 ---
WORKDIR="$HOME/webrtc_desktop_setup"
echo -e "${YELLOW}--> 步骤 3: 准备工作目录和工具...${NC}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -f "webrtc-streamer" ]; then
    echo "下载webrtc-streamer..."
    wget -q --show-progress https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz
    tar -xvf webrtc-streamer-v*.tar.gz && mv webrtc-streamer-*/webrtc-streamer . && rm -rf webrtc-streamer-v*.tar.gz webrtc-streamer-*/
fi
echo -e "${GREEN}✓ 工作目录与工具准备就绪!${NC}"
echo " "

# --- 步骤 4: 启动远程桌面核心服务 ---
echo -e "${YELLOW}--> 步骤 4: 启动远程桌面核心服务...${NC}"
# 直接占用物理屏幕 :0
export DISPLAY=:0
WHD_RESOLUTION="1600x900x24"
LISTENING_PORT="8000"

# 如果物理屏幕不存在（非常罕见的情况），我们才自己创建一个
if [ ! -S "$X0_SOCKET" ]; then
    echo "未发现物理屏幕，正在创建虚拟屏幕..."
    sudo Xorg -noreset +extension GLX +extension RANDR +extension RENDER -logfile /dev/null -config /etc/X11/xorg.conf :0 &
    sleep 3
fi

if nvidia-smi &> /dev/null; then
    echo -e "${GREEN}✓ 检测到 NVIDIA GPU! 将以硬件加速模式启动 (NVENC).${NC}"
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    echo -e "${YELLOW}! 未检测到 NVIDIA GPU。将以软件编码模式启动 (CPU).${NC}"
    VCODEC_OPTION="vcodec=h264"
fi

cleanup() {
    echo " " && echo -e "${BLUE}--- 正在关闭所有服务... ---${NC}" && pkill -P $$ &>/dev/null && echo "清理完成。"
}
trap cleanup EXIT INT TERM

echo "启动最小化XFCE桌面核心..."
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
echo -e "3. 在打开的网页上，点击第一个链接即可进入桌面。"
echo " "
echo -e "按 ${YELLOW}Ctrl+C${NC} 可以停止此脚本和所有远程桌面服务。"
echo " "
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
