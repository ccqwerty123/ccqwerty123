#!/bin/bash

# --- 配置区 ---
WHD_RESOLUTION="1600x900x24"
LISTENING_PORT="8000"
export DISPLAY=:1

# --- 颜色代码 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- 核心：检测NVIDIA GPU ---
if nvidia-smi &> /dev/null; then
    echo -e "${GREEN}✓ NVIDIA GPU detected! Starting with HARDWARE acceleration (NVENC).${NC}"
    VCODEC_OPTION="vcodec=h264_nvenc"
else
    echo -e "${YELLOW}! No NVIDIA GPU detected. Starting with SOFTWARE encoding (CPU).${NC}"
    echo -e "${YELLOW}  (Performance will be lower, and CPU usage will be high.)${NC}"
    VCODEC_OPTION="vcodec=h264"
fi

echo " "
echo "--- Starting Services ---"

# --- 进程清理函数 ---
cleanup() {
    echo " "
    echo "--- Shutting down services ---"
    pkill -P $$
    echo "Cleanup complete."
}
trap cleanup EXIT INT TERM

# 1. 启动虚拟屏幕 (Xvfb)
echo "Starting virtual screen (Xvfb) on display $DISPLAY with resolution $WHD_RESOLUTION..."
Xvfb $DISPLAY -screen 0 $WHD_RESOLUTION &
sleep 2

# 2. 启动XFCE桌面环境
echo "Starting XFCE desktop environment..."
startxfce4 &
sleep 2

# 3. 启动x11vnc作为屏幕捕捉源
echo "Starting x11vnc screen source..."
x11vnc -display $DISPLAY -nopw -quiet -forever &

# 4. 启动WebRTC流媒体服务器
echo "Starting WebRTC streamer..."
echo -e "Streaming server will listen on: ${GREEN}http://0.0.0.0:${LISTENING_PORT}${NC}"
echo " "
echo "--- READY ---"
echo -e "1. Please forward TCP port ${YELLOW}${LISTENING_PORT}${NC} in your Cloud Studio interface."
echo -e "2. Open the public URL provided by Cloud Studio in your web browser."
echo "Press Ctrl+C here to stop all services."
echo " "

# 根据检测结果，执行对应的命令
./webrtc-streamer -H 0.0.0.0:${LISTENING_PORT} "vnc://localhost${DISPLAY}?${VCODEC_OPTION}"
