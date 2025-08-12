#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v15.0 - “NVIDIA硬件加速”终极版)
# ===================================================================================
#
#  此版本为最理想的硬件加速方案，旨在实现 GPU 渲染 + GPU 编码。
#  ✅ NVIDIA 虚拟屏幕: 修改 xorg.conf，强制 Xorg 使用 NVIDIA 驱动创建虚拟屏幕，实现 GPU 渲染。
#  ✅ 端到端硬件加速:  Xorg 使用 GPU 渲染桌面，webrtc-streamer 使用 GPU (NVENC) 编码视频。
#  ✅ 性能最优:         这是理论上能达到的最佳性能方案。
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
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v15.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 0: 终极强制清理 ---
echo -e "${YELLOW}--> 步骤 0: 正在执行终极清理...${NC}"
sudo killall -q -9 Xorg Xvfb xfce4-session xfwm4 webrtc-streamer startx dbus-daemon &>/dev/null
sudo pkill -f "main.py" &>/dev/null
sudo rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 &>/dev/null
echo -e "${GREEN}✓ 清理完成!${NC}"
echo " "

# --- 步骤 1: 依赖安装 ---
echo -e "${YELLOW}--> 步骤 1: 正在安装所有依赖...${NC}"
# 注意：我们重新使用 xorg
required_packages=(xorg xinit lsof xfce4 dbus-x11 wget debconf-utils)
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${required_packages[@]}"
echo -e "${GREEN}✓ 所有依赖已确认安装。${NC}"
echo " "

# --- 步骤 2: 创建 NVIDIA 虚拟屏幕配置文件 ---
echo -e "${YELLOW}--> 步骤 2: 正在创建 NVIDIA 虚拟屏幕配置文件...${NC}"
# **关键修复**: 创建一个专门用于 NVIDIA 的 xorg.conf
# 它会强制 Xorg 加载 nvidia 驱动，并利用 "UseDisplayDevice" "none" 创建一个无头屏幕
sudo tee /etc/X11/xorg.conf > /dev/null <<'EOF'
Section "ServerLayout"
    Identifier "Layout0"
    Screen 0 "Screen0" 0 0
EndSection

Section "Device"
    Identifier "Device0"
    Driver "nvidia"
    VendorName "NVIDIA Corporation"
    BoardName "Tesla T4"  # 可以改成你的显卡型号，或者保持通用
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Monitor "Monitor0"
    DefaultDepth 24
    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "none"
    SubSection "Display"
        Depth 24
        Modes "1600x900"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync 30.0 - 80.0
    VertRefresh 60.0
EndSection
EOF
echo -e "${GREEN}✓ NVIDIA 配置文件 /etc/X11/xorg.conf 创建成功!${NC}"
echo " "

# --- 步骤 3: 准备工具 ---
WORKDIR="$HOME/webrtc_desktop_setup"
cd "$WORKDIR"
if [ ! -f "webrtc-streamer" ]; then wget -qO- https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz | tar zx --strip-components=1; fi
echo -e "${GREEN}✓ 工具已就绪!${NC}"
echo " "

# --- 步骤 4: 启动远程桌面核心服务 ---
echo -e "${YELLOW}--> 步骤 4: 启动硬件加速的 X Server 并注入 DBus 会话...${NC}"
export DISPLAY=:0
LISTENING_PORT="8000"

# 启动硬件加速的 Xorg 服务器
sudo Xorg :0 &
sleep 5 # 等待 X Server 完全启动
echo "硬件加速的 Xorg 已启动。"

# 启动完整的 XFCE 桌面
dbus-launch --exit-with-session xfce4-session &
sleep 5
echo -e "${GREEN}✓ 完整的 XFCE 图形环境已在后台启动!${NC}"

# 必须使用 NVENC 编码器
VCODEC_OPTION="vcodec=h264_nvenc"

echo "------------------------------------------------------"
echo -e "${GREEN}启动 WebRTC 直播... 访问端口 ${LISTENING_PORT} 进入桌面${NC}"
echo "------------------------------------------------------"
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
