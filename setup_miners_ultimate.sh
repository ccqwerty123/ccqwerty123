#!/bin.bash
#
# KeyHunt (CPU) 和 BitCrack (GPU) 的全自动安装与验证脚本 (最终整合版)
# 该脚本整合了指定的核心依赖包，通过自动检测GPU计算能力来解决编译失败问题，
# 并在编译成功后运行帮助命令来验证安装。
#

# --- Bash 颜色代码，用于美化输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # 无颜色

# --- 设置脚本在遇到任何错误时立即停止执行 ---
set -e

# --- 函数：检测 NVIDIA GPU 的计算能力（Compute Capability） ---
detect_compute_capability() {
    echo -e "${YELLOW}---> 正在检测 NVIDIA GPU 计算能力...${NC}"
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${RED}错误: 未找到 'nvidia-smi' 命令。${NC}"
        echo -e "${RED}这可能是因为 nvidia-cuda-toolkit 尚未完全配置或需要重启。如果此步骤失败，请尝试重启服务器后再运行脚本。${NC}"
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
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN}  开始安装并验证 KeyHunt 和 BitCrack             ${NC}"
    echo -e "${GREEN}=====================================================${NC}"

    # 1. 安装系统依赖 (已整合您的请求)
    echo -e "\n${YELLOW}---> 第 1 步: 安装所有系统依赖包...${NC}"
    sudo apt-get update
    # 下面这行已包含您指定的 git, build-essential, nvidia-cuda-toolkit
    # 以及 KeyHunt 和 BitCrack 所需的其他所有依赖。
    sudo apt-get install -y git build-essential cmake python3 python3-pip libgmp-dev libsecp256k1-dev ocl-icd-opencl-dev nvidia-cuda-toolkit
    echo -e "${GREEN}---> 依赖包安装成功。${NC}"


    # 2. 安装 KeyHunt (CPU 版本)
    echo -e "\n${YELLOW}---> 第 2 步: 克隆并编译 KeyHunt (来自 albertobsd)...${NC}"
    if [ -d "keyhunt" ]; then
        echo "keyhunt 目录已存在，跳过克隆。"
    else
        git clone https://github.com/albertobsd/keyhunt.git
    fi
    cd keyhunt
    make clean
    make -j$(nproc)
    
    if [ -f "keyhunt" ]; then
        echo -e "${GREEN}---> KeyHunt 编译成功！${NC}"
        echo -e "${YELLOW}---> 正在验证安装 (显示帮助信息)...${NC}"
        ./keyhunt -h
        echo -e "${GREEN}---> KeyHunt 验证成功！可执行文件位于: $(pwd)/keyhunt${NC}"
    else
        echo -e "${RED}---> KeyHunt 编译失败！${NC}"
        exit 1
    fi
    cd ..


    # 3. 安装 BitCrack (GPU 版本)
    echo -e "\n${YELLOW}---> 第 3 步: 克隆并编译 BitCrack (用于 GPU)...${NC}"
    
    local DETECTED_CAP
    DETECTED_CAP=$(detect_compute_capability)

    if [ -d "BitCrack" ]; then
        echo "BitCrack 目录已存在，跳过克隆。"
    else
        git clone https://github.com/brichard19/BitCrack.git
    fi
    cd BitCrack
    
    echo -e "${YELLOW}---> 使用检测到的 COMPUTE_CAP=${DETECTED_CAP} 开始 'make' 编译...${NC}"
    make clean
    make -j$(nproc) BUILD_CUDA=1 BUILD_OPENCL=1 COMPUTE_CAP="${DETECTED_CAP}"

    if [ -f "bitcrack" ]; then
        echo -e "${GREEN}---> BitCrack 编译成功！${NC}"
        echo -e "${YELLOW}---> 正在验证安装 (显示帮助信息)...${NC}"
        ./bitcrack --help
        echo -e "${GREEN}---> BitCrack 验证成功！可执行文件位于: $(pwd)/bitcrack${NC}"
    else
        echo -e "${RED}---> BitCrack 编译失败！请检查上方的错误信息。${NC}"
        exit 1
    fi
    cd ..


    echo -e "\n${GREEN}=====================================================${NC}"
    echo -e "${GREEN}      所有程序安装并验证完毕！                     ${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "您现在可以在 Python 脚本中使用以下可执行文件了:"
    echo -e "KeyHunt (CPU):   $(pwd)/keyhunt/keyhunt"
    echo -e "BitCrack (GPU):  $(pwd)/BitCrack/bitcrack"
    echo -e "下一步: 准备您的 Python 自动化脚本和目标地址文件。"
}

# --- 运行主函数 ---
main
