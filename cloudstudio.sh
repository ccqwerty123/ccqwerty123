#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v7.0 - “稳定优先”版)
# ===================================================================================
#
#  此版本为最终解决方案，具备以下特性：
#  ✅ 强制清理:       不仅清理屏幕，还主动结束已知的其他UI进程。
#  ✅ 稳定启动:       增加延时，确保桌面服务完全就绪后再启动直播流。
#  ✅ 进程守护:       使用循环保持脚本存活，防止因意外退出导致桌面关闭。
#  ✅ 非交互安装:     修正了依赖安装可能被中断的问题。
#
# ===================================================================================

# --- 美化输出的颜色定义 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

clear
echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v7.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 0: 清理已知的冲突进程 (如ComfyUI) ---
echo -e "${YELLOW}--> 步骤 0: 正在结束其他UI进程 (例如: ComfyUI)...${NC}"
# 通过查找运行 main.py 并监听 8188 端口的进程来精确查杀
PIDS_TO_KILL_COMFY=$(sudo lsof -t -i:8188 2>/dev/null)
if [ -n "$PIDS_TO_KILL_COMFY" ]; then
    echo "发现 ComfyUI 进程，正在结束它..."
    echo "$PIDS_TO_KILL_COMfy" | xargs sudo kill -9
    echo -e "${GREEN}✓ ComfyUI 已被关闭!${NC}"
else
    echo -e "${GREEN}✓ 未发现活动的 ComfyUI 进程。${NC}"
fi
echo " "


# --- 步骤 1: 智能依赖检查与安装 (修正版) ---
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
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends "${packages_to_install[@]}"
    echo -e "${GREEN}✓ 所有依赖已成功安装!${NC}"
else
    echo -e "${GREEN}✓ 所有依赖均已安装。${NC}"
fi
echo " "


# --- 步骤 2: 精确清理物理屏幕 :0 ---
X0_SOCKET="/tmp/.X11-unix/X0"
echo -e "${YELLOW}--> 步骤 2: 正在检查并清理物理屏幕 :0 ...${NC}"
if [ -S "$X0_SOCKET" ]; then
    PIDS_TO_KILL=$(sudo lsof -t "$X0_SOCKET" 2>/dev/null)
    if [ -n "$PIDS_TO_KILL" ]; then
        echo -e "发现以下进程正在占用屏幕:0，将强制结束它们:\n${PIDS_TO_KILL}"
        echo "$PIDS_TO_KILL" | xargs sudo kill -9
        sleep 2
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
export DISPLAY=:0
LISTENING_PORT="8000"

# 启动一个虚拟X Server作为我们的屏幕
sudo Xorg -noreset +extension GLX +extension RANDR +extension RENDER -logfile /dev/null -config /etc/X11/xorg.conf :0 &
# **关键改动**: 等待X Server完全启动
sleep 5
echo "虚拟屏幕已启动。"

if nvidia-smi &> /dev/null; then
    echo -e "${GREEN}✓ 检测到 NVIDIA GPU! 将以硬件加速模式启动 (NVENC).${NC}"
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    echo -e "${YELLOW}! 未检测到 NVIDIA GPU。将以软件编码模式启动 (CPU).${NC}"
    VCODEC_OPTION="vcodec=h264"
fi

echo "启动最小化XFCE桌面核心..."
xfce4-session &
xfwm4 &
# **关键改动**: 增加延时，确保桌面服务有足够时间启动
sleep 5
echo "XFCE会话已启动。"

# 启动直播推流，现在它应该能找到桌面了
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}" &
echo -e "${GREEN}✓ WebRTC 直播服务已在后台启动。${NC}"

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
echo -e "脚本将持续运行以保持桌面服务。按 ${YELLOW}Ctrl+C${NC} 可以停止。"
echo " "

# **关键改动**: 使用一个无限循环来防止脚本退出，从而保持所有后台服务存活
while true; do sleep 3600; done
