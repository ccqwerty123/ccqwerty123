#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 3.0.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v3.0.0 更新日志:
# 核心变更: 严格遵循 "必须使用 g++-9 或更低版本编译器" 的要求。
# - 新增: 编译器自动发现机制。脚本会按 g++-9, g++-8, g++-7 的顺序查找
#   系统中已安装的兼容编译器。
# - 新增: 如果未找到任何兼容编译器，脚本将安全退出并提供清晰的中文
#   安装指引。
# - 保留: 继承了 v2.x 版本中所有关键的源代码修复补丁，以解决 C++ 标准
#   兼容性和平台特定函数问题。
# ==============================================================================
#
# 功能特性:
# - 自动检查依赖项 (git, build-essential, libssl-dev)。
# - 智能检测 NVIDIA 驱动和 CUDA 工具包。
# - 自动检测 GPU 的计算能力 (Compute Capability, ccap)。
# - [v2.0+] 自动修复多个 C++ 源代码文件因缺少 <cstdint> 引发的编译错误。
# - [v2.2+] 自动修复因使用 MSVC 特定函数 _byteswap_ulong 导致的编译错误。
# - 自动配置 Makefile 文件。
# - 为网络操作提供重试逻辑。
# - 提供彩色的、详细的中文输出，提升用户体验。
#

# --- 配置信息 ---
SCRIPT_VERSION="3.0.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
REQUIRED_CMDS=("git" "make")
REQUIRED_HEADERS=("/usr/include/openssl/ssl.h")
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

# 查找一个兼容的旧版本 g++ 编译器
find_compatible_compiler() {
    log_info "正在查找兼容的 g++ 编译器 (版本 <= 9)..."
    for compiler in "${COMPATIBLE_COMPILERS[@]}"; do
        if command -v "$compiler" &>/dev/null; then
            DETECTED_CXXCUDA=$(command -v "$compiler")
            log_success "已找到并选定兼容的编译器: ${C_BOLD}$DETECTED_CXXCUDA${C_RESET}"
            return
        fi
    done

    log_error "未在您的系统中找到任何兼容的 g++ 编译器 (g++-9, g++-8, 或 g++-7)。\n         根据官方要求, 此项目必须使用 g++-9 或更低版本进行编译。\n         请从上述列表中选择一个进行安装, 例如:\n         ${C_BOLD}sudo apt update && sudo apt install g++-9${C_RESET}"
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
        "${PROJECT_DIR}/Timer.h"
        "${PROJECT_DIR}/hash/sha512.h"
        "${PROJECT_DIR}/hash/sha256.h"
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
    local file_to_patch_bswap="${PROJECT_DIR}/hash/sha256.cpp"
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
    cd "$PROJECT_DIR"
    if [ ! -f "Makefile" ]; then
        log_error "在项目目录中未找到 Makefile 文件。"
    fi
    # 使用 sed 的 -i 选项来直接修改文件。注意不同版本的 sed 语法可能略有差异。
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
        log_error "编译失败。尽管已使用旧版编译器并应用了补丁，但仍然出错。\n         请检查上方的详细编译日志以获取线索。"
    fi
    cd ..
}

# --- 主执行逻辑 ---
main() {
    echo -e "${C_BOLD}--- alek76-2/VanitySearch 自动化安装脚本 (v${SCRIPT_VERSION}) ---${C_RESET}"
    log_info "此版本将严格遵循官方建议, 自动查找并使用 g++-9 或更低版本的编译器。"
    echo "----------------------------------------------------"
    sleep 2

    # 步骤 1: 检查基础环境
    check_dependencies
    
    # 步骤 2: 查找兼容的编译器 (关键步骤)
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
