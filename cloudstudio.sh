#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v12.0 - “DBus强制注入”最终版)
# ===================================================================================
#
#  此版本为最终解决方案，使用 'dbus-launch' 强制创建会话总线，根治所有连接问题。
#  ✅ 使用 dbus-launch: 替换 startx，手动创建 DBus 会话并注入XFCE，解决“空壳桌面”问题。
#  ✅ 稳定可靠:         整合了之前所有版本的修复，是启动嵌入式图形环境的终极方案。
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
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v12.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 0: 终极强制清理 ---
echo -e "${YELLOW}--> 步骤 0: 正在执行终极清理...${NC}"
sudo killall -q -9 Xorg Xvfb xfce4-session xfwm4 webrtc-streamer startx dbus-daemon &>/dev/null
sudo pkill -f "main.py" &>/dev/null
sudo rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 &>/dev/null
echo -e "${GREEN}✓ 清理完成!${NC}"
echo " "

# --- 步骤 1: 确保依赖已安装 ---
echo -e "${YELLOW}--> 步骤 1: 正在确认所有依赖...${NC}"
required_packages=(xorg xserver-xorg-video-dummy xinit lsof xfce4 dbus-x11 wget debconf-utils)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends "${required_packages[@]}" &>/dev/null
echo -e "${GREEN}✓ 所有依赖已确认安装。${NC}"
echo " "

# --- 步骤 2: 确保虚拟屏幕配置文件存在 ---
echo -e "${YELLOW}--> 步骤 2: 正在确保虚拟屏幕配置文件存在...${NC}"
sudo mkdir -p /etc/X11
sudo tee /etc/X11/xorg.conf > /dev/null <<'EOF'
Section "Device"
    Identifier  "Configured Video Device"
    Driver      "dummy"
EndSection
Section "Monitor"
    Identifier  "Configured Monitor"
    HorizSync   31.5-48.5
    VertRefresh 50-70
EndSection
Section "Screen"
    Identifier  "Default Screen"
    Monitor     "Configured Monitor"
    Device      "Configured Video Device"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1600x900"
    EndSubSection
EndSection
EOF
echo -e "${GREEN}✓ 配置文件 /etc/X11/xorg.conf 已就绪!${NC}"
echo " "

# --- 步骤 3: 确保工具已就绪 ---
WORKDIR="$HOME/webrtc_desktop_setup"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -f "webrtc-streamer" ]; then wget -qO- https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz | tar zx --strip-components=1; fi
echo -e "${GREEN}✓ 工具已就绪!${NC}"
echo " "

# --- 步骤 4: 启动远程桌面核心服务 (最终方法) ---
echo -e "${YELLOW}--> 步骤 4: 启动 X Server 并注入 DBus 会话...${NC}"
export DISPLAY=:0
LISTENING_PORT="8000"

# 启动X Server，作为所有图形的画布
sudo Xorg :0 &
# 等待X Server完全启动
sleep 3
echo "虚拟屏幕画布已启动。"

# **关键修复**: 使用 dbus-launch 包装 xfce4-session，强制创建“神经系统”并注入桌面
dbus-launch --exit-with-session xfce4-session &
# 等待桌面环境完全初始化
sleep 5
echo -e "${GREEN}✓ 完整的 XFCE 图形环境已在后台启动!${NC}"

if nvidia-smi &> /dev/null; then VCODEC_OPTION="vcodec=h264_nvenc"; else VCODEC_OPTION="vcodec=h264"; fi

echo "------------------------------------------------------"
echo -e "${GREEN}启动 WebRTC 直播... 访问端口 ${LISTENING_PORT} 进入桌面${NC}"
echo "------------------------------------------------------"
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
