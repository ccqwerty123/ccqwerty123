#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 3.2.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v3.2.0 更新日志:
# - 新增: APT 源健康检查与自动修复机制。脚本在执行 'apt update' 前, 会先
#   模拟更新以检测返回错误的源文件 (如 404 Not Found)。
# - 新增: 安全的临时禁用与自动恢复功能。如果检测到问题源 (例如 modular.list),
#   脚本会征求用户同意 (带超时确认), 将其临时重命名。
# - 新增: 使用 'trap' 命令确保无论脚本如何退出 (成功、失败、被中断),
#   被禁用的源文件都会被自动恢复, 保证了系统的完整性。
# ==============================================================================
#
# 功能特性:
# - [v3.2+] 自动诊断并安全地临时修复损坏的 APT 软件源。
# - [v3.1+] 自动检查并尝试安装缺失的旧版本编译器 (g++-9)。
# - 智能检测 NVIDIA 驱动和 CUDA 工具包及 GPU 计算能力。
# - 自动修复源代码中的 C++ 兼容性错误。
# - 自动配置 Makefile 文件并编译。
# - 提供彩色的、详细的中文输出。
#

# --- 配置信息 ---
SCRIPT_VERSION="3.2.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
REQUIRED_PKGS=("build-essential" "git" "libssl-dev")
COMPATIBLE_COMPILERS=("g++-9" "g++-8" "g++-7")
MAX_RETRIES=3
DISABLED_SOURCES_FILES=() # 用于记录被禁用的源文件

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
log_info() { echo -e "${C_CYAN}[信息]${C_RESET} $1"; }
log_success() { echo -e "${C_GREEN}[成功]${C_RESET} ${C_BOLD}$1${C_RESET}"; }
log_warn() { echo -e "${C_YELLOW}[警告]${C_RESET} $1"; }
log_error() { echo -e "${C_RED}[错误]${C_RESET} $1" >&2; exit 1; }

# --- 核心功能函数 ---

# 恢复被临时禁用的 APT 源文件。此函数由 trap 调用，确保总能执行。
cleanup_sources() {
    if [ ${#DISABLED_SOURCES_FILES[@]} -gt 0 ]; then
        log_info "正在恢复被临时禁用的 APT 源文件..."
        for src_file in "${DISABLED_SOURCES_FILES[@]}"; do
            if [ -f "${src_file}.disabled_by_script" ]; then
                sudo mv "${src_file}.disabled_by_script" "$src_file"
                log_success "已恢复 $src_file"
            fi
        done
    fi
}

# 设置 trap，无论脚本如何退出，都执行 cleanup_sources 函数
trap cleanup_sources EXIT

# APT 源健康检查与修复
check_and_fix_apt_sources() {
    log_info "正在进行 APT 软件源健康检查..."
    local update_output
    # 使用 sudo -E 保留环境变量, 捕获 stderr, 超时 60 秒
    update_output=$(sudo -E apt-get update 2>&1) || true
    
    # 查找返回 403, 404 等错误的行，并提取文件名
    local problem_files
    problem_files=$(echo "$update_output" | grep -E 'Err:|Fehler:' | grep -oP '(?<=InRelease ).*' | xargs -I {} find /etc/apt/sources.list.d/ -name '*.list' -exec grep -l "{}" {} + | sort -u)

    if [ -z "$problem_files" ]; then
        log_success "APT 软件源健康状况良好。"
        return
    fi
    
    log_warn "检测到以下 APT 源文件可能存在问题:"
    echo -e "${C_YELLOW}$problem_files${C_RESET}"
    
    echo -e -n "${C_YELLOW}是否允许脚本临时禁用这些文件以继续安装？(Y/n) [将在 15 秒后自动确认]: ${C_RESET}"
    local user_input=""
    if read -t 15 user_input; then
        if [[ "$user_input" =~ ^[Nn]$ ]]; then
            log_error "用户拒绝修复。请手动修复 APT 源后重试: sudo apt update"
        fi
    else
        echo ""
        log_info "超时无响应，已默认选择 '是'。"
    fi

    for file_to_disable in $problem_files; do
        log_info "正在临时禁用: $file_to_disable"
        sudo mv "$file_to_disable" "${file_to_disable}.disabled_by_script"
        DISABLED_SOURCES_FILES+=("$file_to_disable")
        log_success "已临时禁用 $file_to_disable"
    done
    
    log_info "正在重新运行 APT 更新以确认修复..."
    if ! sudo apt-get update; then
        log_error "即使在禁用问题源后, 'apt update' 依然失败。请手动检查您的 APT 配置。"
    fi
    log_success "APT 更新成功，问题已临时解决。"
}

# 查找或安装兼容的 g++ 编译器
find_or_install_compiler() {
    log_info "正在查找兼容的 g++ 编译器 (版本 <= 9)..."
    for compiler in "${COMPATIBLE_COMPILERS[@]}"; do
        if command -v "$compiler" &>/dev/null; then
            DETECTED_CXXCUDA=$(command -v "$compiler")
            log_success "已找到并选定兼容的编译器: ${C_BOLD}$DETECTED_CXXCUDA${C_RESET}"
            return
        fi
    done

    log_warn "未找到兼容的 g++ 编译器。脚本将尝试自动安装 ${COMPATIBLE_COMPILERS[0]}。"
    echo -e -n "${C_YELLOW}您是否同意执行 ${C_BOLD}'sudo apt install ${COMPATIBLE_COMPILERS[0]} -y'${C_RESET}？(Y/n) [将在 15 秒后自动确认]: ${C_RESET}"
    
    local user_input=""
    if read -t 15 user_input; then
        if [[ "$user_input" =~ ^[Nn]$ ]]; then log_error "用户拒绝自动安装。脚本已中止。"; fi
    else
        echo ""; log_info "超时无响应，已默认选择 '是'。"
    fi

    log_info "正在执行安装命令..."
    if ! { sudo apt-get install -y "${COMPATIBLE_COMPILERS[0]}"; }; then
        log_error "自动安装 ${COMPATIBLE_COMPILERS[0]} 失败。请手动安装后重试。"
    fi
    log_success "成功安装 ${COMPATIBLE_COMPILERS[0]}。"
    
    if ! command -v "${COMPATIBLE_COMPILERS[0]}" &>/dev/null; then
        log_error "安装后依然无法找到 ${COMPATIBLE_COMPILERS[0]} 命令。"
    fi
    DETECTED_CXXCUDA=$(command -v "${COMPATIBLE_COMPILERS[0]}")
}


# 检查 NVIDIA 驱动和 CUDA 环境
check_nvidia_cuda() {
    log_info "正在检查 NVIDIA GPU 环境..."
    if ! command -v nvidia-smi &>/dev/null; then log_error "未找到 NVIDIA 驱动 ('nvidia-smi')。请安装官方驱动并重启。"; fi
    log_success "已检测到 NVIDIA 驱动。"

    if ! command -v nvcc &>/dev/null; then log_error "未找到 NVIDIA CUDA 工具包 ('nvcc')。请从 NVIDIA 官网安装。"; fi
    local cuda_version; cuda_version=$(nvcc --version | grep "release" | sed 's/.*release \([^,]*\).*/\1/')
    log_success "已检测到 NVIDIA CUDA 工具包 (版本: $cuda_version)。"

    log_info "正在检测 GPU 计算能力 (ccap)..."
    local compute_cap; compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n 1)
    if [ -z "$compute_cap" ]; then log_error "无法确定 GPU 计算能力。"; fi
    DETECTED_CCAP=$(echo "$compute_cap" | tr -d '.')
    log_success "检测到 GPU 计算能力: $compute_cap (ccap: ${DETECTED_CCAP})"
    
    DETECTED_CUDA_PATH="/usr/local/cuda"
    if [ ! -d "$DETECTED_CUDA_PATH" ]; then
        log_warn "标准 CUDA 路径 '$DETECTED_CUDA_PATH' 不存在。将假定 'nvcc' 路径已配置。"
        DETECTED_CUDA_PATH=""
    else
         log_success "找到 CUDA 安装路径: $DETECTED_CUDA_PATH"
    fi
}

# 下载源代码
download_source() {
    log_info "正在下载 VanitySearch 源代码..."
    if [ -d "$PROJECT_DIR" ]; then
        log_warn "目录 '$PROJECT_DIR' 已存在，将删除以进行全新安装。"
        rm -rf "$PROJECT_DIR"
    fi

    for ((i=1; i<=MAX_RETRIES; i++)); do
        if git clone --quiet "$GITHUB_REPO"; then
            log_success "源代码下载成功。"
            cd "$PROJECT_DIR"
            return
        fi
        log_warn "Git 克隆失败 (尝试 $i/$MAX_RETRIES)。3 秒后重试..."
        sleep 3
    done
    
    log_error "尝试 $MAX_RETRIES 次后，克隆仓库失败。"
}

# 应用源代码补丁
patch_source_code() {
    log_info "正在应用源代码补丁以修复编译错误..."
    local files_to_patch_cstdint=("Timer.h" "hash/sha512.h" "hash/sha256.h")
    for file_path in "${files_to_patch_cstdint[@]}"; do
        if [ -f "$file_path" ] && ! grep -q "#include <cstdint>" "$file_path"; then
            sed -i '1i#include <cstdint>\n' "$file_path"
            log_success "为 ${file_path##*/} 添加了 #include <cstdint> 补丁。"
        fi
    done
    
    local file_to_patch_bswap="hash/sha256.cpp"
    if [ -f "$file_to_patch_bswap" ]; then
        sed -i '/#define WRITEBE32/i \
#ifdef __GNUC__\
#include <byteswap.h>\
#define _byteswap_ulong(x) bswap_32(x)\
#endif\
' "$file_to_patch_bswap"
        log_success "为 sha256.cpp 添加了字节序反转函数兼容性补丁。"
    fi
}

# 配置 Makefile
configure_makefile() {
    log_info "正在根据您的系统环境配置 Makefile..."
    if [ ! -f "Makefile" ]; then log_error "未找到 Makefile 文件。"; fi
    sed -i "s|^CUDA       = .*|CUDA       = ${DETECTED_CUDA_PATH}|" Makefile
    sed -i "s|^CXXCUDA    = .*|CXXCUDA    = ${DETECTED_CXXCUDA}|" Makefile
    log_success "Makefile 配置已自动完成。"
}

# 编译
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
    local start_dir; start_dir=$(pwd)
    
    echo -e "${C_BOLD}--- alek76-2/VanitySearch 自动化安装脚本 (v${SCRIPT_VERSION}) ---${C_RESET}"
    echo -e "此版本会自动诊断并临时修复失效的 APT 软件源。"
    echo "----------------------------------------------------"
    sleep 2

    # 步骤 1: APT 源健康检查与修复 (新增的关键步骤)
    check_and_fix_apt_sources

    # 步骤 2: 查找或安装兼容的编译器
    find_or_install_compiler

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
