#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 3.1.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v3.1.0 更新日志:
# - 新增: 自动依赖安装。当检测到缺少兼容的 g++ 编译器时，脚本会提示并
#   尝试使用 'sudo apt install' 自动安装 (默认安装 g++-9)。
# - 新增: 超时自动确认机制。在执行安装前，脚本会等待 15 秒供用户确认。
#   若无任何输入，则自动继续，以适应非交互式终端环境。
# - 优化: 改进了编译器查找逻辑，使其在安装后能无缝衔接。
# ==============================================================================
#
# 功能特性:
# - 自动检查并尝试安装依赖项 (git, build-essential, libssl-dev, g++-9)。
# - 智能检测 NVIDIA 驱动和 CUDA 工具包。
# - 自动检测 GPU 的计算能力 (Compute Capability, ccap)。
# - 自动修复多个 C++ 源代码文件因缺少 <cstdint> 引发的编译错误。
# - 自动修复因使用 MSVC 特定函数 _byteswap_ulong 导致的编译错误。
# - 自动配置 Makefile 文件。
# - 为网络操作提供重试逻辑。
# - 提供彩色的、详细的中文输出，提升用户体验。
#

# --- 配置信息 ---
SCRIPT_VERSION="3.1.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
REQUIRED_CMDS=("git" "make")
REQUIRED_PKGS=("build-essential" "git" "libssl-dev")
# 定义兼容的编译器列表，按从新到旧的顺序排列
COMPATIBLE_COMPILERS=("g++-9" "g++-8" "g++-7")
MAX_RETRIES=3

# --- Shell 安全设置与颜色定义 ---
set -o errexit
set -o nounset
set -o pipefail

# 颜色定义
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- 日志函数 ---
log_info() {
    echo -e "${C_CYAN}[信息]${C_RESET} $1"
}
log_success() {
    echo -e "${C_GREEN}[成功]${C_RESET} ${C_BOLD}$1${C_RESET}"
}
log_warn() {
    echo -e "${C_YELLOW}[警告]${C_RESET} $1"
}
log_error() {
    echo -e "${C_RED}[错误]${C_RESET} $1" >&2
    exit 1
}

# --- 核心功能函数 ---

# 检查系统所需的基础命令和库文件。
check_dependencies() {
    log_info "正在检查系统基础依赖项..."
    # 检查软件包是否已安装
    local missing_pkgs=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        log_warn "检测到以下基础软件包缺失: ${missing_pkgs[*]}"
        log_error "请先手动安装它们后重试: sudo apt update && sudo apt install ${missing_pkgs[*]}"
    fi
    
    # 检查命令是否存在
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "命令 '$cmd' 未找到。请确保 'build-essential' 和 'git' 已正确安装。"
        fi
    done
    log_success "所有基础依赖项均已安装。"
}

# 查找一个兼容的旧版本 g++ 编译器，如果找不到则尝试安装
find_compatible_compiler() {
    local is_retry=${1:-"false"} # 接收一个可选参数，判断是否为重试调用
    if [ "$is_retry" == "false" ]; then
        log_info "正在查找兼容的 g++ 编译器 (版本 <= 9)..."
    fi

    for compiler in "${COMPATIBLE_COMPILERS[@]}"; do
        if command -v "$compiler" &>/dev/null; then
            DETECTED_CXXCUDA=$(command -v "$compiler")
            if [ "$is_retry" == "false" ]; then
                log_success "已找到并选定兼容的编译器: ${C_BOLD}$DETECTED_CXXCUDA${C_RESET}"
            fi
            return
        fi
    done

    # 如果是重试调用且仍未找到，则说明安装失败
    if [ "$is_retry" == "true" ]; then
        log_error "即使在尝试安装后，依然无法找到兼容的编译器。脚本无法继续。"
    fi

    # 首次未找到，触发自动安装逻辑
    log_warn "未在您的系统中找到任何兼容的 g++ 编译器 (g++-9, g++-8, 或 g++-7)。"
    log_info "脚本将尝试自动为您安装 ${C_BOLD}${COMPATIBLE_COMPILERS[0]}${C_RESET}。"
    echo -e -n "${C_YELLOW}您是否同意执行 ${C_BOLD}'sudo apt update && sudo apt install ${COMPATIBLE_COMPILERS[0]} -y'${C_RESET}？(Y/n) [将在 15 秒后自动确认]: ${C_RESET}"
    
    local user_input=""
    if read -t 15 user_input; then
        if [[ "$user_input" =~ ^[Nn]$ ]]; then
            log_error "用户拒绝自动安装。脚本已中止。"
        fi
    else
        echo "" # 超时后换行以保持格式
        log_info "超时无响应，已默认选择 '是'。"
    fi

    log_info "正在执行安装命令... 这可能需要您的管理员密码。"
    if ! { sudo apt-get update && sudo apt-get install -y "${COMPATIBLE_COMPILERS[0]}"; }; then
        log_error "自动安装 ${COMPATIBLE_COMPILERS[0]} 失败。请检查您的 apt 配置或手动安装后重试。"
    fi
    log_success "成功安装 ${COMPATIBLE_COMPILERS[0]}。"
    
    # 安装后再次调用自身进行查找
    find_compatible_compiler "retry"
}

# 检查 NVIDIA 驱动和 CUDA 环境, 并检测相关属性。
check_nvidia_cuda() {
    log_info "正在检查 NVIDIA GPU 环境..."
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "未找到 NVIDIA 驱动。'nvidia-smi' 命令执行失败。请为您的 GPU 安装合适的 NVIDIA 官方驱动并重启系统。"
    fi
    log_success "已检测到 NVIDIA 驱动。"

    if ! command -v nvcc &>/dev/null; then
        log_error "未找到 NVIDIA CUDA 工具包。'nvcc' 命令执行失败。请从 NVIDIA 官网下载并安装 CUDA Toolkit。"
    fi
    local cuda_version
    cuda_version=$(nvcc --version | grep "release" | sed 's/.*release \([^,]*\).*/\1/')
    log_success "已检测到 NVIDIA CUDA 工具包 (版本: $cuda_version)。"

    log_info "正在检测 GPU 计算能力 (ccap)..."
    local compute_cap
    compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1)
    if [ -z "$compute_cap" ]; then
        log_error "无法确定 GPU 计算能力。请检查您的 'nvidia-smi' 是否工作正常。"
    fi
    DETECTED_CCAP=$(echo "$compute_cap" | tr -d '.')
    log_success "检测到 GPU 计算能力: $compute_cap (对应的 ccap 值为 ${DETECTED_CCAP})"
    
    DETECTED_CUDA_PATH="/usr/local/cuda"
    if [ ! -d "$DETECTED_CUDA_PATH" ]; then
        log_warn "标准 CUDA 路径 '$DETECTED_CUDA_PATH' 不存在。将假定 'nvcc' 已经在系统 PATH 中。"
        DETECTED_CUDA_PATH=""
    else
         log_success "找到 CUDA 安装路径: $DETECTED_CUDA_PATH"
    fi
}

# 下载源代码，包含重试逻辑。
download_source() {
    log_info "正在下载 VanitySearch 源代码..."
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "目录 '$PROJECT_DIR' 已存在。将删除该目录以进行全新安装。"
        rm -rf "$PROJECT_DIR"
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if git clone --quiet "$GITHUB_REPO"; then
            log_success "源代码下载成功。"
            cd "$PROJECT_DIR"
            return 0
        fi
        log_warn "Git 克隆失败 (尝试次数 $i/$MAX_RETRIES)。将在 3 秒后重试..."
        sleep 3
    done
    
    log_error "尝试 $MAX_RETRIES 次后，克隆仓库失败。"
}

# 应用补丁修复 C++ 兼容性导致的编译错误
patch_source_code() {
    log_info "正在应用源代码补丁以修复编译错误..."
    
    # 定义需要添加 <cstdint> 的文件列表
    local files_to_patch_cstdint=(
        "Timer.h"
        "hash/sha512.h"
        "hash/sha256.h"
    )

    for file_path in "${files_to_patch_cstdint[@]}"; do
        if [ -f "$file_path" ]; then
            if ! grep -q "#include <cstdint>" "$file_path"; then
                sed -i '1i#include <cstdint>\n' "$file_path"
                log_success "成功为 ${file_path##*/} 添加 #include <cstdint> 补丁。"
            fi
        else
            log_warn "需要打补丁的文件 '$file_path' 不存在，已跳过。"
        fi
    done
    
    # 修复平台特定的 _byteswap_ulong 函数
    local file_to_patch_bswap="hash/sha256.cpp"
    if [ -f "$file_to_patch_bswap" ]; then
        # 使用 #ifdef __GNUC__ 来为 GCC/Clang 提供 __builtin_bswap32 替代方案
        sed -i '/#define WRITEBE32/i \
#ifdef __GNUC__\
#include <byteswap.h>\
#define _byteswap_ulong(x) bswap_32(x)\
#endif\
' "$file_to_patch_bswap"
        log_success "成功为 sha256.cpp 添加字节序反转函数的兼容性补丁。"
    else
         log_warn "需要打补丁的文件 '$file_to_patch_bswap' 不存在，已跳过。"
    fi
}

# 根据检测到的环境动态配置 Makefile。
configure_makefile() {
    log_info "正在根据您的系统环境配置 Makefile..."
    if [ ! -f "Makefile" ]; then
        log_error "在项目目录中未找到 Makefile 文件。"
    fi
    sed -i "s|^CUDA       = .*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile
    sed -i "s|^CXXCUDA    = .*|CXXCUDA    = ${DETECTED_CXXCUDA}|" Makefile
    log_success "Makefile 配置已自动完成。"
}

# 编译源代码。
compile_source() {
    log_info "开始编译... 这可能需要几分钟时间。"
    make clean > /dev/null 2>&1 || true
    if make -j$(nproc) gpu=1 ccap=${DETECTED_CCAP} all; then
        log_success "编译成功完成！"
    else
        log_error "编译失败。请检查上方的详细编译日志以获取线索。"
    fi
}

# --- 主执行逻辑 ---
main() {
    local start_dir
    start_dir=$(pwd)
    
    echo -e "${C_BOLD}--- alek76-2/VanitySearch 自动化安装脚本 (v${SCRIPT_VERSION}) ---${C_RESET}"
    echo -e "此版本会自动检测并安装缺失的旧版编译器 (${C_YELLOW}g++-9${C_RESET})。"
    echo "----------------------------------------------------"
    sleep 2

    # 步骤 1: 检查基础环境
    check_dependencies
    
    # 步骤 2: 查找或安装兼容的编译器
    find_compatible_compiler

    # 步骤 3: 检查 NVIDIA 环境
    check_nvidia_cuda

    # 步骤 4: 下载源代码
    download_source

    # 步骤 5: 应用修复补丁
    patch_source_code

    # 步骤 6: 配置 Makefile
    configure_makefile

    # 步骤 7: 编译
    compile_source
    
    # 返回初始目录
    cd "$start_dir"

    echo "----------------------------------------------------"
    log_success "VanitySearch 已成功安装！"
    log_info "可执行文件位于: ${C_BOLD}${start_dir}/${PROJECT_DIR}/VanitySearch${C_RESET}"
    log_info "您可以像这样运行它:"
    echo -e "  cd ${PROJECT_DIR}"
    echo -e "  ./VanitySearch -gpu 1MyPrefix"
    echo ""
    log_warn "安全提醒: 请务必小心处理您生成的私钥。将其离线、安全地备份。"
    echo "----------------------------------------------------"
}

# 运行主函数
main
