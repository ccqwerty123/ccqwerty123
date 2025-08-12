#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v17.0 - “零信任混合加速”最终版)
# ===================================================================================
#
#  此版本为基于所有调试日志的最终解决方案，采取“零信任”原则和最稳健的“混合加速”策略。
#  ✅ 诊断结论:         环境的 NVIDIA 显示驱动损坏，无法进行 GPU 渲染，但视频编码单元可能可用。
#  ✅ 混合加速策略:    【最终方案】使用最稳定的 Xvfb 进行 CPU 渲染，同时尝试使用 NVENC 进行 GPU 视频编码。
#  ✅ 零信任验证:       【强制】在安装后主动验证每一个核心组件是否存在，如不存在则报错停止。
#  ✅ 稳定与性能兼顾:   此方案是当前环境下性能与稳定性的理论最优解。
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
echo -e "${BLUE}  🚀 启动 Cloud Studio 远程桌面部署 (v17.0)... ${NC}"
echo -e "${BLUE}======================================================${NC}"
echo " "

# --- 步骤 0: 终极强制清理 ---
echo -e "${YELLOW}--> 步骤 0: 正在执行终极清理...${NC}"
sudo killall -q -9 Xorg Xvfb xfce4-session xfwm4 webrtc-streamer startx dbus-daemon &>/dev/null
sudo pkill -f "main.py" &>/dev/null
sudo rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 &>/dev/null
echo -e "${GREEN}✓ 清理完成!${NC}"
echo " "

# --- 步骤 1: 依赖安装与强制验证 ---
echo -e "${YELLOW}--> 步骤 1: 正在安装并强制验证 Xvfb 方案所需依赖...${NC}"
required_packages=(xvfb xinit lsof xfce4 dbus-x11 wget)
packages_to_install=()
for pkg in "${required_packages[@]}"; do
    if ! dpkg -s "$pkg" &> /dev/null; then
        packages_to_install+=("$pkg")
    fi
done

if [ ${#packages_to_install[@]} -ne 0 ]; then
    echo "发现缺失的依赖: ${packages_to_install[*]}"
    echo "正在全自动安装 (此过程可能需要几分钟，请耐心等待)..."
    sudo apt-get update -y
    # **关键**: 去掉静默参数，让安装过程完全可见
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages_to_install[@]}"
    echo -e "${GREEN}✓ 依赖安装命令已执行。现在开始验证...${NC}"
else
    echo -e "${GREEN}✓ 所有依赖似乎已安装。现在开始验证...${NC}"
fi

# **关键**: 恢复并加强强制验证步骤
CRITICAL_CMDS=(Xvfb dbus-launch xfce4-session)
for cmd in "${CRITICAL_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${RED}=========================== 致命错误 ==========================${NC}"
        echo -e "${RED}  验证失败: 核心命令 '$cmd' 未找到!                       ${NC}"
        echo -e "${RED}  这表示依赖安装过程失败。请检查上面的安装日志寻找错误。 ${NC}"
        echo -e "${RED}==============================================================${NC}"
        exit 1
    fi
done
echo -e "${GREEN}✓ 所有核心组件均已成功安装并验证!${NC}"
echo " "


# --- 步骤 2: 准备工具 ---
WORKDIR="$HOME/webrtc_desktop_setup"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [ ! -f "webrtc-streamer" ]; then wget -qO- https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz | tar zx --strip-components=1; fi
echo -e "${GREEN}✓ 工具已就绪!${NC}"
echo " "

# --- 步骤 3: 启动远程桌面核心服务 ---
echo -e "${YELLOW}--> 步骤 3: 启动 Xvfb 画布 (CPU渲染) 并注入 DBus 会话...${NC}"
export DISPLAY=:0
LISTENING_PORT="8000"

# 使用 Xvfb 启动一个 1600x900x24 的纯内存虚拟屏幕
sudo Xvfb :0 -screen 0 1600x900x24 -ac +extension GLX +render -noreset &
sleep 3
echo "纯内存虚拟屏幕 (Xvfb) 已启动。"

# 使用 dbus-launch 启动完整的 XFCE 桌面
dbus-launch --exit-with-session xfce4-session &
sleep 5
echo -e "${GREEN}✓ 完整的 XFCE 图形环境已在后台启动!${NC}"

# 智能判断是否可以使用 NVENC 进行 GPU 视频编码
if nvidia-smi &> /dev/null; then
    echo -e "${GREEN}✓ 检测到 NVIDIA GPU! 将尝试使用 NVENC 进行硬件视频编码。${NC}"
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    echo -e "${YELLOW}! 未检测到 NVIDIA GPU。将使用 CPU 进行软件视频编码。${NC}"
    VCODEC_OPTION="vcodec=h264"
fi

echo "------------------------------------------------------"
echo -e "${GREEN}启动 WebRTC 直播... 访问端口 ${LISTENING_PORT} 进入桌面${NC}"
echo "------------------------------------------------------"
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "x11:${DISPLAY}?${VCODEC_OPTION}"
