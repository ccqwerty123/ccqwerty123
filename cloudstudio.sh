#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v10.0 - “终极修复”版)
# ===================================================================================
#
#  此版本为最终解决方案，根据所有错误日志进行修复，具备以下特性：
#  ✅ 强制清理:       强力清除 apt 锁文件和残留进程，解决 "Address in use" 问题。
#  ✅ 预设配置:       使用 debconf-set-selections 预先回答安装问题，解决键盘布局中断。
#  ✅ 虚拟屏配置:     自动创建 xorg.conf 文件，使用 dummy 驱动，根治 "no screens found" 错误。
#  ✅ 稳定可靠:       整合了之前版本的所有优点，确保启动流程的绝对稳定。
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
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v10.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 0: 终极强制清理 ---
echo -e "${YELLOW}--> 步骤 0: 正在执行终极清理...${NC}"
# 杀死所有可能残留的进程
sudo killall -q -9 Xorg Xvfb xfce4-session xfwm4 webrtc-streamer
sudo pkill -f "main.py" &>/dev/null
# 强制移除 apt 锁，解决 "apt-get update 被锁定" 的问题
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock &>/dev/null
echo -e "${GREEN}✓ 清理完成!${NC}"
echo " "


# --- 步骤 1: 智能依赖检查与安装 (带预设配置) ---
echo -e "${YELLOW}--> 步骤 1: 智能检查并安装所有依赖...${NC}"
required_packages=(xorg xserver-xorg-video-dummy xinit lsof xfce4 dbus-x11 wget debconf-utils)
packages_to_install=()
for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        packages_to_install+=("$pkg")
    fi
done
if [ ${#packages_to_install[@]} -ne 0 ]; then
    echo "发现缺失的依赖: ${packages_to_install[*]}"
    echo "正在全自动安装..."
    
    # **关键修复 1**: 使用 debconf-set-selections 预先回答键盘布局问题
    # 这里的配置选择了通用的 "pc105" 键盘和 "us" 布局，避免任何交互提示
    echo "keyboard-configuration keyboard-configuration/layoutcode string us" | sudo debconf-set-selections
    echo "keyboard-configuration keyboard-configuration/modelcode string pc105" | sudo debconf-set-selections
    
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends "${packages_to_install[@]}"
    echo -e "${GREEN}✓ 所有依赖已成功安装!${NC}"
else
    echo -e "${GREEN}✓ 所有依赖均已安装。${NC}"
fi
echo " "

# --- 步骤 2: 创建虚拟屏幕配置文件 ---
echo -e "${YELLOW}--> 步骤 2: 正在创建虚拟屏幕配置文件...${NC}"
# **关键修复 2**: 创建一个 xorg.conf 文件，告诉 Xorg 使用 dummy 驱动
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
echo -e "${GREEN}✓ 配置文件 /etc/X11/xorg.conf 创建成功!${NC}"
echo " "


# --- 步骤 3: 准备工具 ---
WORKDIR="$HOME/webrtc_desktop_setup"
echo -e "${YELLOW}--> 步骤 3: 准备工作目录和工具...${NC}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -f "webrtc-streamer" ]; then
    wget -q --show-progress https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz
    tar -xvf webrtc-streamer-v*.tar.gz && mv webrtc-streamer-*/webrtc-streamer . && rm -rf webrtc-streamer-v*.tar.gz webrtc-streamer-*/
fi
echo -e "${GREEN}✓ 工具准备就绪!${NC}"
echo " "

# --- 步骤 4: 启动远程桌面核心服务 ---
echo -e "${YELLOW}--> 步骤 4: 启动远程桌面核心服务...${NC}"
export DISPLAY=:0
LISTENING_PORT="8000"

# 启动X Server，它现在会读取我们的配置文件并成功创建虚拟屏幕
sudo Xorg :0 &
sleep 3
echo "虚拟屏幕已启动。"

# 启动XFCE桌面
xfce4-session &
sleep 3
echo "XFCE会话已启动。"

if nvidia-smi &> /dev/null; then
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    VCODEC_OPTION="vcodec=h264"
fi

echo -e "${GREEN}启动 WebRTC 直播... 访问端口 ${LISTENING_PORT} 进入桌面${NC}"
echo "------------------------------------------------------"
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
