#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 2.1.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# 功能特性:
# - 自动检查依赖项 (git, build-essential, libssl-dev)。
# - 智能检测 NVIDIA 驱动和 CUDA 工具包。
# - 自动检测 GPU 的计算能力 (Compute Capability, ccap)。
# - [v2.0.0] 自动修复 'Timer.h' 中 'uint32_t' 未定义的编译错误。
# - [v2.1.0] 自动修复 'hash/sha512.h' 中 'uint8_t/uint64_t' 未定义的编译错误。
# - 自动配置 Makefile 文件。
# - 为网络操作提供重试逻辑。
# - 提供彩色的、详细的中文输出，提升用户体验。
# - 在环境不满足要求时，会安全失败并给出清晰的中文指引。
#

# --- 配置信息 ---
SCRIPT_VERSION="2.1.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
REQUIRED_CMDS=("git" "g++" "make")
REQUIRED_HEADERS=("/usr/include/openssl/ssl.h")
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
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "命令 '$cmd' 未找到。请先安装它。在 Debian/Ubuntu 系统上, 请尝试: sudo apt install build-essential git"
        fi
    done
    for header in "${REQUIRED_HEADERS[@]}"; do
        if [ ! -f "$header" ]; then
            log_error "头文件 '$header' 未找到。请安装 OpenSSL 开发库。在 Debian/Ubuntu 系统上, 请尝试: sudo apt install libssl-dev"
        fi
    done
    log_success "所有基础依赖项均已安装。"
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
    log_success "检测到 GPU 计算能力: $compute_cap (对应的 ccap值为 ${DETECTED_CCAP})"
    
    if command -v g++-7 &>/dev/null; then
        DETECTED_CXXCUDA="/usr/bin/g++-7"
    elif command -v g++-8 &>/dev/null; then
        DETECTED_CXXCUDA="/usr/bin/g++-8"
    else
        DETECTED_CXXCUDA=$(command -v g++)
        log_warn "未找到特定的旧版本 g++ (如 g++-7)。将使用系统默认版本 '$DETECTED_CXXCUDA'。如果编译失败, 您可能需要手动安装一个与 CUDA 兼容的 g++ 版本。"
    fi
    log_success "已选择 g++ 编译器: $DETECTED_CXXCUDA"

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
        if git clone "$GITHUB_REPO"; then
            log_success "源代码下载成功。"
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
    
    # 补丁 1: 修复 Timer.h
    local file_to_patch_1="${PROJECT_DIR}/Timer.h"
    if [ -f "$file_to_patch_1" ]; then
        if ! grep -q "#include <cstdint>" "$file_to_patch_1"; then
            sed -i '1i#include <cstdint>\n' "$file_to_patch_1"
            log_success "成功为 Timer.h 添加 #include <cstdint> 补丁。"
        else
            log_info "补丁已存在于 Timer.h，跳过。"
        fi
    else
        log_error "需要打补丁的文件 '$file_to_patch_1' 不存在。"
    fi

    # 补丁 2: 修复 hash/sha512.h
    local file_to_patch_2="${PROJECT_DIR}/hash/sha512.h"
    if [ -f "$file_to_patch_2" ]; then
        if ! grep -q "#include <cstdint>" "$file_to_patch_2"; then
            sed -i '1i#include <cstdint>\n' "$file_to_patch_2"
            log_success "成功为 hash/sha512.h 添加 #include <cstdint> 补丁。"
        else
            log_info "补丁已存在于 hash/sha512.h，跳过。"
        fi
    else
        log_error "需要打补丁的文件 '$file_to_patch_2' 不存在。"
    fi
}

# 根据检测到的环境动态配置 Makefile。
configure_makefile() {
    log_info "正在根据您的系统环境配置 Makefile..."
    cd "$PROJECT_DIR"
    if [ ! -f "Makefile" ]; then
        log_error "在项目目录中未找到 Makefile 文件。"
    fi
    sed -i "s|^CUDA       = .*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile
    sed -i "s|^CXXCUDA    = .*|CXXCUDA    = ${DETECTED_CXXCUDA}|" Makefile
    log_success "Makefile 配置已自动完成。"
    cd ..
}

# 编译源代码。
compile_source() {
    log_info "开始编译... 这可能需要几分钟时间。"
    cd "$PROJECT_DIR"
    make clean > /dev/null 2>&1 || true
    if make -j$(nproc) gpu=1 ccap=${DETECTED_CCAP} all; then
        log_success "编译成功完成！"
    else
        log_error "编译失败。请检查上方的错误信息。常见问题包括:\n  - CUDA 和 g++ 版本不兼容。\n  - NVIDIA 驱动安装不正确。"
    fi
    cd ..
}

# --- 主执行逻辑 ---
main() {
    echo -e "${C_BOLD}--- alek76-2/VanitySearch 自动化安装脚本 (v${SCRIPT_VERSION}) ---${C_RESET}"
    log_warn "本脚本将尝试从源代码编译软件，但不会使用 root 权限安装任何系统级软件包 (如驱动或编译器)。"
    log_warn "在运行本脚本前，请确保您已手动安装了 NVIDIA 驱动和 CUDA 工具包。"
    echo "----------------------------------------------------"
    sleep 2

    check_dependencies
    check_nvidia_cuda
    download_source
    patch_source_code
    configure_makefile
    compile_source

    echo "----------------------------------------------------"
    log_success "VanitySearch 已成功安装！"
    log_info "可执行文件位于: ${C_BOLD}$(pwd)/${PROJECT_DIR}/VanitySearch${C_RESET}"
    log_info "您可以像这样运行它:"
    echo -e "  cd ${PROJECT_DIR}"
    echo -e "  ./VanitySearch -gpu 1MyPrefix"
    echo ""
    log_warn "安全提醒: 请务必小心处理您生成的私钥。将其离线、安全地备份。"
    echo "----------------------------------------------------"
}

# 运行主函数
main
