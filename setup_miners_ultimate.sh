#!/bin.bash
#
# KeyHunt (CPU) 和 BitCrack (GPU) 的全自动安装与验证脚本
# 版本: 1.2.0 - 幂等版
#
# 特性:
# 1. 版本控制: 启动时显示版本号。
# 2. 幂等性: 重复运行会跳过已完成的安装，不会重复下载或编译。
# 3. 自动纠错: 自动检测GPU计算能力，自动处理'make clean'错误。
# 4. 最终验证: 无论是否新安装，最后都会验证程序能否正常运行。
#

# --- 脚本版本 ---
SCRIPT_VERSION="1.2.0 - 幂等版"

# --- Bash 颜色代码 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 脚本在遇到任何错误时立即停止执行 ---
set -e

# --- 函数：检测 NVIDIA GPU 的计算能力 ---
detect_compute_capability() {
    # ... (此函数内容未变) ...
    echo -e "${YELLOW}---> 正在检测 NVIDIA GPU 计算能力...${NC}"
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${RED}错误: 未找到 'nvidia-smi' 命令。${NC}"
        echo -e "${RED}在运行此脚本前，请确保已正确安装 NVIDIA 驱动和 CUDA 工具包。${NC}"
        exit 1
    fi
    COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | head -n 1 | tr -d '.')
    if [ -z "$COMPUTE_CAP" ]; then
        echo -e "${RED}错误: 无法确定 GPU 计算能力。请检查您的 GPU 是否被驱动支持。${NC}"
        exit 1
    fi
    echo -e "${GREEN}---> 已检测到计算能力为: ${COMPUTE_CAP}${NC}"
    echo "$COMPUTE_CAP"
}

# --- 主脚本逻辑 ---
main() {
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}  运行安装脚本 ${SCRIPT_VERSION}               ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    # 1. 安装系统依赖
    echo -e "\n${YELLOW}---> 第 1 步: 安装系统依赖包...${NC}"
    echo -e "${YELLOW}# 注: apt-get 会自动跳过已安装的包，此步骤可重复安全运行。${NC}"
    sudo apt-get update
    sudo apt-get install -y build-essential git cmake python3 python3-pip libgmp-dev libsecp256k1-dev ocl-icd-opencl-dev nvidia-cuda-toolkit
    echo -e "${GREEN}---> 依赖包检查与安装完成。${NC}"

    # 2. 安装 KeyHunt (CPU 版本)
    echo -e "\n${YELLOW}---> 第 2 步: 检查并安装 KeyHunt (用于 CPU)...${NC}"
    if [ ! -f "keyhunt/keyhunt" ]; then
        echo -e "未找到 keyhunt 可执行文件，开始全新安装..."
        if [ -d "keyhunt" ]; then
            echo "发现旧的keyhunt目录，将进行清理..."
            rm -rf keyhunt
        fi
        git clone https://github.com/albertobsd/keyhunt.git
        cd keyhunt
        make clean || true
        make -j$(nproc)
        cd ..
        echo -e "${GREEN}---> KeyHunt 全新安装成功！${NC}"
    else
        echo -e "${GREEN}--->检测到 keyhunt 已安装，跳过安装步骤。${NC}"
    fi
    # 最终验证 (无论是否新安装都执行)
    echo -e "${YELLOW}---> 正在验证 KeyHunt...${NC}"
    ./keyhunt/keyhunt -h
    echo -e "${GREEN}---> KeyHunt 验证成功！${NC}"

    # 3. 安装 BitCrack (GPU 版本)
    echo -e "\n${YELLOW}---> 第 3 步: 检查并安装 BitCrack (用于 GPU)...${NC}"
    if [ ! -f "BitCrack/bitcrack" ]; then
        echo -e "未找到 bitcrack 可执行文件，开始全新安装..."
        if [ -d "BitCrack" ]; then
            echo "发现旧的BitCrack目录，将进行清理..."
            rm -rf BitCrack
        fi

        local DETECTED_CAP
        DETECTED_CAP=$(detect_compute_capability)

        git clone https://github.com/brichard19/BitCrack.git
        cd BitCrack
        echo -e "${YELLOW}---> 使用检测到的 COMPUTE_CAP=${DETECTED_CAP} 开始 'make' 编译...${NC}"
        make clean || true
        make -j$(nproc) BUILD_CUDA=1 BUILD_OPENCL=1 COMPUTE_CAP="${DETECTED_CAP}"
        cd ..
        echo -e "${GREEN}---> BitCrack 全新安装成功！${NC}"
    else
        echo -e "${GREEN}---> 检测到 bitcrack 已安装，跳过安装步骤。${NC}"
    fi
    # 最终验证 (无论是否新安装都执行)
    echo -e "${YELLOW}---> 正在验证 BitCrack...${NC}"
    ./BitCrack/bitcrack --help
    echo -e "${GREEN}---> BitCrack 验证成功！${NC}"


    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}      所有程序安装并验证完毕！ (版本: ${SCRIPT_VERSION})${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "您现在可以在 Python 脚本中使用以下可执行文件了:"
    echo -e "KeyHunt (CPU):   $(pwd)/keyhunt/keyhunt"
    echo -e "BitCrack (GPU):  $(pwd)/BitCrack/bitcrack"
}

# --- 运行主函数 ---
main
