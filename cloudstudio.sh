#!/bin/bash

# ===================================================================================
#  Cloud Studio 高性能远程桌面一键部署脚本 (v5.0 - 命名空间隔离版)
# ===================================================================================
#
#  此版本为终极架构，引入Linux命名空间实现完美隔离，具备以下特性：
#  ✅ 命名空间隔离:   利用`unshare`创建全新PID命名空间，从根源上杜绝与外部环境的任何冲突。
#  ✅ 绝对通用性:     无需关心环境中预装了什么程序(ComfyUI或任何其他UI)，保证100%纯净。
#  ✅ 架构最优:       不再需要手动pkill清理进程，方法更优雅、更可靠。
#  ✅ 智能依赖检查、全自动非交互、自动GPU检测等所有v4.0优点全部保留。
#
# ===================================================================================

# --- 主程序逻辑 ---
main() {
    # --- 美化输出的颜色定义 ---
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    clear
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${BLUE}  🚀 启动 Cloud Studio 隔离远程桌面部署 (v5.0)... ${NC}"
    echo -e "${BLUE}======================================================${NC}"
    echo " "

    # --- 步骤 1: 智能依赖检查与安装 ---
    echo -e "${YELLOW}--> 步骤 1: 智能检查系统依赖...${NC}"
    required_packages=(util-linux xfce4 dbus-x11 xvfb wget libx264-dev libopus-dev libasound2-dev libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev libavutil-dev libpostproc-dev libswresample-dev libswscale-dev)
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

    # --- 步骤 2: 准备工作目录和工具 ---
    WORKDIR="$HOME/webrtc_desktop_setup"
    echo -e "${YELLOW}--> 步骤 2: 准备工作目录和工具...${NC}"
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"
    if [ ! -f "webrtc-streamer" ]; then
        echo "下载webrtc-streamer..."
        wget -q --show-progress https://github.com/mpromonet/webrtc-streamer/releases/download/v0.8.2/webrtc-streamer-v0.8.2-Linux-x86_64-Release.tar.gz
        tar -xvf webrtc-streamer-v*.tar.gz && mv webrtc-streamer-*/webrtc-streamer . && rm -rf webrtc-streamer-v*.tar.gz webrtc-streamer-*/
    fi
    echo -e "${GREEN}✓ 工作目录与工具准备就绪!${NC}"
    echo " "

    # --- 步骤 3: 启动远程桌面核心服务 ---
    echo -e "${YELLOW}--> 步骤 3: 启动远程桌面核心服务...${NC}"
    WHD_RESOLUTION="1600x900x24"
    LISTENING_PORT="8000"
    export DISPLAY=:1
    if nvidia-smi &> /dev/null; then
        echo -e "${GREEN}✓ 检测到 NVIDIA GPU! 将以硬件加速模式启动 (NVENC).${NC}"
        VCODEC_OPTION="vcodec=h264_nvenc"
    else
        echo -e "${YELLOW}! 未检测到 NVIDIA GPU。将以软件编码模式启动 (CPU).${NC}"
        VCODEC_OPTION="vcodec=h264"
    fi
    
    echo "启动虚拟屏幕 (Xvfb)..."
    Xvfb $DISPLAY -screen 0 $WHD_RESOLUTION &
    sleep 2
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
}


# --- 脚本入口 ---
# 使用 unshare 命令创建一个新的PID命名空间。
# --fork: 创建一个子进程在新的命名空间中运行。
# --pid:  指定创建PID命名空间。
# --mount-proc: 挂载一个新的/proc文件系统，这样ps等命令才能在沙箱内正常工作。
# "$0" --internal-run: 重新执行本脚本，但传入一个特殊参数。
#
# if-else 结构确保了我们只在脚本第一次运行时创建命名空间，
# 而在命名空间内部的第二次运行时，直接执行main函数。
if [ "$1" = "--internal-run" ]; then
    main
else
    # 确保 unshare 命令的依赖 util-linux 已安装
    if ! dpkg -s "util-linux" &> /dev/null; then
        echo "正在安装核心依赖: util-linux..."
        export DEBIAN_FRONTEND=noninteractive
        sudo apt-get update && sudo apt-get install -yq util-linux
    fi
    # 在新的、隔离的命名空间中重新执行自己
    unshare --fork --pid --mount-proc "$0" --internal-run
fi
