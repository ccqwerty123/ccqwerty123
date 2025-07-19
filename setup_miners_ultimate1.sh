#!/bin.bash
#
# KeyHunt (CPU) 和 BitCrack (GPU) 的全自动安装与验证脚本
# 版本: 1.3.1 - 智能COMPUTE_CAP检测版
#
# 特性:
# 1. 版本控制: 启动时显示版本号。
# 2. 幂等性: 重复运行会跳过已完成的安装。
# 3. 智能验证: 通过捕获帮助命令的输出来判断是否成功，并显示输出。
# 4. 最终总结: 在脚本末尾明确报告每个工具的最终安装状态。
# 5. 智能COMPUTE_CAP检测: 检查已安装的BitCrack是否使用了正确的COMPUTE_CAP值。
#

# --- 脚本版本 ---
SCRIPT_VERSION="1.3.1 - 智能COMPUTE_CAP检测版"

# --- Bash 颜色代码 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- 脚本在遇到任何错误时立即停止执行 ---
set -e

# --- 用于最终总结的状态变量 ---
KEYHUNT_SUCCESS=false
BITCRACK_SUCCESS=false

# --- 函数：检测 NVIDIA GPU 的计算能力 ---
detect_compute_capability() {
    echo -e "${YELLOW}---> 正在检测 NVIDIA GPU 计算能力...${NC}"
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${RED}错误: 未找到 'nvidia-smi' 命令。${NC}"
        exit 1
    fi
    COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits | head -n 1 | tr -d '.')
    if [ -z "$COMPUTE_CAP" ]; then
        echo -e "${RED}错误: 无法确定 GPU 计算能力。${NC}"
        exit 1
    fi
    echo -e "${GREEN}---> 已检测到计算能力为: ${COMPUTE_CAP}${NC}"
    echo "$COMPUTE_CAP"
}

# --- 函数：检查Makefile中的COMPUTE_CAP值 ---
check_makefile_compute_cap() {
    local makefile_path="$1"
    local current_cap="$2"
    
    if [ ! -f "$makefile_path" ]; then
        echo "false"
        return
    fi
    
    # 从Makefile中提取COMPUTE_CAP值
    local makefile_cap=$(grep -E "^COMPUTE_CAP\s*=" "$makefile_path" 2>/dev/null | head -n 1 | sed 's/.*=\s*//' | tr -d ' ')
    
    if [ -z "$makefile_cap" ]; then
        echo "false"
        return
    fi
    
    echo -e "${CYAN}---> Makefile中的COMPUTE_CAP: ${makefile_cap}${NC}"
    echo -e "${CYAN}---> 当前GPU的COMPUTE_CAP: ${current_cap}${NC}"
    
    if [ "$makefile_cap" = "$current_cap" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# --- 函数：安装BitCrack ---
install_bitcrack() {
    local detected_cap="$1"
    local reason="$2"
    
    echo -e "${YELLOW}---> ${reason}，开始安装BitCrack...${NC}"
    [ -d "BitCrack" ] && rm -rf BitCrack
    
    git clone https://github.com/brichard19/BitCrack.git
    cd BitCrack
    echo -e "${YELLOW}---> 使用检测到的 COMPUTE_CAP=${detected_cap} 开始 'make' 编译...${NC}"
    make clean || true
    make -j$(nproc) BUILD_CUDA=1 BUILD_OPENCL=1 COMPUTE_CAP="${detected_cap}"
    cd ..
    echo -e "${GREEN}---> BitCrack 安装完成！${NC}"
}

# --- 主脚本逻辑 ---
main() {
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}  运行安装脚本 ${SCRIPT_VERSION}               ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    # 1. 安装系统依赖
    echo -e "\n${YELLOW}---> 第 1 步: 检查并安装系统依赖包...${NC}"
    sudo apt-get update
    sudo apt-get install -y build-essential git cmake python3 python3-pip libgmp-dev libsecp256k1-dev ocl-icd-opencl-dev nvidia-cuda-toolkit
    echo -e "${GREEN}---> 依赖包检查与安装完成。${NC}"

    # 2. 安装 KeyHunt
    echo -e "\n${YELLOW}---> 第 2 步: 检查并安装 KeyHunt (用于 CPU)...${NC}"
    if [ ! -f "keyhunt/keyhunt" ]; then
        echo -e "未找到 keyhunt 可执行文件，开始全新安装..."
        [ -d "keyhunt" ] && rm -rf keyhunt
        git clone https://github.com/albertobsd/keyhunt.git
        cd keyhunt
        make clean || true
        make -j$(nproc)
        cd ..
        echo -e "${GREEN}---> KeyHunt 全新安装完成！${NC}"
    else
        echo -e "${GREEN}---> 检测到 keyhunt 已安装，跳过安装步骤。${NC}"
    fi
    
    # 验证 KeyHunt
    echo -e "${YELLOW}---> 正在验证 KeyHunt...${NC}"
    # 捕获帮助命令的输出，如果命令失败则输出为空
    validation_output=$(./keyhunt/keyhunt -h 2>/dev/null || true)
    if [ -n "$validation_output" ]; then
        echo -e "${CYAN}--- KeyHunt 帮助信息 ---${NC}"
        echo "$validation_output"
        echo -e "${CYAN}--------------------------${NC}"
        KEYHUNT_SUCCESS=true
    else
        echo -e "${RED}---> KeyHunt 验证失败：无法执行或没有帮助信息输出。${NC}"
    fi

    # 3. 安装 BitCrack
    echo -e "\n${YELLOW}---> 第 3 步: 检查并安装 BitCrack (用于 GPU)...${NC}"
    
    # 检测当前GPU的计算能力
    local DETECTED_CAP
    DETECTED_CAP=$(detect_compute_capability)
    
    # 检查是否需要安装或重新安装BitCrack
    local need_install=false
    local install_reason=""
    
    if [ ! -f "BitCrack/bin/cuBitCrack" ]; then
        need_install=true
        install_reason="未找到 BitCrack 可执行文件"
    else
        echo -e "${GREEN}---> 检测到 BitCrack 已安装，正在检查COMPUTE_CAP配置...${NC}"
        
        # 检查Makefile中的COMPUTE_CAP值是否匹配
        local cap_match=$(check_makefile_compute_cap "BitCrack/Makefile" "$DETECTED_CAP")
        
        if [ "$cap_match" = "false" ]; then
            need_install=true
            install_reason="Makefile中的COMPUTE_CAP值与当前GPU不匹配，需要重新编译"
        else
            echo -e "${GREEN}---> COMPUTE_CAP配置正确，跳过安装步骤。${NC}"
        fi
    fi
    
    # 根据检查结果决定是否安装
    if [ "$need_install" = true ]; then
        install_bitcrack "$DETECTED_CAP" "$install_reason"
    fi
    
    # 验证 BitCrack
    echo -e "${YELLOW}---> 正在验证 BitCrack...${NC}"
    if [ -f "BitCrack/bin/cuBitCrack" ]; then
        validation_output=$(./BitCrack/bin/cuBitCrack --help 2>/dev/null || true)
        if [ -n "$validation_output" ]; then
            echo -e "${CYAN}--- BitCrack 帮助信息 ---${NC}"
            echo "$validation_output"
            echo -e "${CYAN}---------------------------${NC}"
            BITCRACK_SUCCESS=true
        else
            echo -e "${RED}---> BitCrack 验证失败：无法执行或没有帮助信息输出。${NC}"
        fi
    else
        echo -e "${RED}---> BitCrack 验证失败：编译后未找到 bin/cuBitCrack 可执行文件。${NC}"
    fi

    # --- 最终总结 ---
    echo -e "\n${CYAN}=====================================================${NC}"
    echo -e "${CYAN}                     安装总结                      ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    if [ "$KEYHUNT_SUCCESS" = true ]; then
        echo -e "  [ ${GREEN}成功${NC} ] KeyHunt (CPU)"
    else
        echo -e "  [ ${RED}失败${NC} ] KeyHunt (CPU)"
    fi

    if [ "$BITCRACK_SUCCESS" = true ]; then
        echo -e "  [ ${GREEN}成功${NC} ] BitCrack (GPU) - COMPUTE_CAP: ${DETECTED_CAP}"
    else
        echo -e "  [ ${RED}失败${NC} ] BitCrack (GPU)"
    fi
    echo -e "${CYAN}=====================================================${NC}"

    echo -e "\n${GREEN}所有检查已完成 (版本: ${SCRIPT_VERSION})。${NC}"
    echo -e "您现在可以在 Python 脚本中使用以下可执行文件了:"
    echo -e "KeyHunt:   $(pwd)/keyhunt/keyhunt"
    echo -e "BitCrack:  $(pwd)/BitCrack/bin/cuBitCrack"
}

# --- 运行主函数 ---
main
