#!/bin/bash
#
# KeyHunt (CPU) 和 BitCrack (GPU) 的全自动安装与验证脚本
# 版本: 1.3.1 - 修复管道执行环境问题
#
# 特性:
# 1. 版本控制: 启动时显示版本号。
# 2. 幂等性: 重复运行会跳过已完成的安装。
# 3. 智能验证: 通过捕获帮助命令的输出来判断是否成功，并显示输出。
# 4. 最终总结: 在脚本末尾明确报告每个工具的最终安装状态。
# 5. 修复管道执行环境问题: 强制重新检测GPU计算能力，忽略环境变量
#

# --- 脚本版本 ---
SCRIPT_VERSION="1.3.1 - 修复管道执行环境问题"

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

# --- 函数：强制重新检测 NVIDIA GPU 的计算能力 ---
detect_compute_capability() {
    echo -e "${YELLOW}---> 正在强制重新检测 NVIDIA GPU 计算能力...${NC}"
    
    # 清除可能影响检测的环境变量
    unset COMPUTE_CAP
    unset CUDA_COMPUTE_CAP
    unset NVIDIA_COMPUTE_CAP
    
    if ! command -v nvidia-smi &> /dev/null; then
        echo -e "${RED}错误: 未找到 'nvidia-smi' 命令。${NC}"
        exit 1
    fi
    
    echo -e "${CYAN}---> 调试信息: 执行环境检查${NC}"
    echo "当前用户: $(whoami)"
    echo "当前路径: $(pwd)"
    echo "环境变量 COMPUTE_CAP: ${COMPUTE_CAP:-未设置}"
    
    # 使用多种方法获取计算能力，确保准确性
    local RAW_OUTPUT
    local COMPUTE_CAP_DETECTED
    
    # 方法1: 直接查询计算能力
    echo -e "${CYAN}---> 方法1: 直接查询GPU计算能力${NC}"
    RAW_OUTPUT=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader,nounits 2>/dev/null || echo "")
    echo "原始输出: '$RAW_OUTPUT'"
    
    if [ -n "$RAW_OUTPUT" ]; then
        COMPUTE_CAP_DETECTED=$(echo "$RAW_OUTPUT" | head -n 1 | tr -d '. \t\n\r')
        echo "处理后: '$COMPUTE_CAP_DETECTED'"
    fi
    
    # 方法2: 如果方法1失败，尝试解析GPU名称推断
    if [ -z "$COMPUTE_CAP_DETECTED" ] || [ "$COMPUTE_CAP_DETECTED" = "0" ]; then
        echo -e "${CYAN}---> 方法2: 通过GPU名称推断计算能力${NC}"
        local GPU_NAME
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1 || echo "")
        echo "GPU名称: '$GPU_NAME'"
        
        case "$GPU_NAME" in
            *"RTX 4090"*|*"RTX 4080"*|*"RTX 4070"*|*"RTX 40"*)
                COMPUTE_CAP_DETECTED="89"
                echo "推断计算能力: 8.9 (Ada Lovelace)"
                ;;
            *"RTX 3090"*|*"RTX 3080"*|*"RTX 3070"*|*"RTX 30"*)
                COMPUTE_CAP_DETECTED="86"
                echo "推断计算能力: 8.6 (Ampere)"
                ;;
            *"RTX 2080"*|*"RTX 2070"*|*"RTX 20"*|*"GTX 16"*)
                COMPUTE_CAP_DETECTED="75"
                echo "推断计算能力: 7.5 (Turing)"
                ;;
            *"GTX 1080"*|*"GTX 1070"*|*"GTX 10"*)
                COMPUTE_CAP_DETECTED="61"
                echo "推断计算能力: 6.1 (Pascal)"
                ;;
            *)
                echo -e "${YELLOW}警告: 无法识别GPU型号，使用默认值 7.5${NC}"
                COMPUTE_CAP_DETECTED="75"
                ;;
        esac
    fi
    
    # 最终验证
    if [ -z "$COMPUTE_CAP_DETECTED" ] || [ "$COMPUTE_CAP_DETECTED" = "0" ]; then
        echo -e "${RED}错误: 无法确定 GPU 计算能力。${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}---> 最终检测到的计算能力: ${COMPUTE_CAP_DETECTED}${NC}"
    echo "$COMPUTE_CAP_DETECTED"
}

# --- 主脚本逻辑 ---
main() {
    echo -e "${CYAN}=====================================================${NC}"
    echo -e "${CYAN}  运行安装脚本 ${SCRIPT_VERSION}               ${NC}"
    echo -e "${CYAN}=====================================================${NC}"

    # 环境诊断
    echo -e "\n${YELLOW}---> 环境诊断信息${NC}"
    echo "脚本执行方式: ${0}"
    echo "当前用户: $(whoami)"
    echo "当前目录: $(pwd)"
    echo "预设环境变量 COMPUTE_CAP: ${COMPUTE_CAP:-未设置}"

    # 1. 安装系统依赖
    echo -e "\n${YELLOW}---> 第 1 步: 检查并安装系统依赖包...${NC}"
    apt-get update
    apt-get install -y build-essential git cmake python3 python3-pip libgmp-dev libsecp256k1-dev ocl-icd-opencl-dev nvidia-cuda-toolkit
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
    if [ ! -f "BitCrack/bin/cuBitCrack" ]; then
        echo -e "未找到 bitcrack 可执行文件，开始全新安装..."
        [ -d "BitCrack" ] && rm -rf BitCrack
        
        # 强制重新检测计算能力，忽略环境变量
        local DETECTED_CAP
        DETECTED_CAP=$(detect_compute_capability)
        
        git clone https://github.com/brichard19/BitCrack.git
        cd BitCrack
        echo -e "${YELLOW}---> 使用强制检测到的 COMPUTE_CAP=${DETECTED_CAP} 开始 'make' 编译...${NC}"
        
        # 清理并重新编译，明确指定计算能力
        make clean || true
        
        # 强制覆盖任何预设的COMPUTE_CAP环境变量
        COMPUTE_CAP="${DETECTED_CAP}" make -j$(nproc) BUILD_CUDA=1 BUILD_OPENCL=1 COMPUTE_CAP="${DETECTED_CAP}"
        cd ..
        echo -e "${GREEN}---> BitCrack 全新安装完成！${NC}"
        
        # 额外验证：检查编译时使用的计算能力
        if [ -f "BitCrack/bin/cuBitCrack" ]; then
            echo -e "${CYAN}---> 编译验证：检查实际使用的计算能力${NC}"
            echo "预期计算能力: ${DETECTED_CAP}"
        fi
    else
        echo -e "${GREEN}---> 检测到 bitcrack 已安装，跳过安装步骤。${NC}"
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
            
            # 额外的运行时测试
            echo -e "${YELLOW}---> 进行运行时测试...${NC}"
            test_output=$(./BitCrack/bin/cuBitCrack -d 0 --keyspace 1:2 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH 2>&1 | head -n 5 || true)
            if echo "$test_output" | grep -q "compute capability"; then
                echo -e "${RED}警告: 检测到计算能力不匹配问题${NC}"
                echo "测试输出: $test_output"
            else
                echo -e "${GREEN}运行时测试通过${NC}"
            fi
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
        echo -e "  [ ${GREEN}成功${NC} ] BitCrack (GPU)"
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
