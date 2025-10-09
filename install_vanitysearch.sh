#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 4.1.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v4.1.0 更新日志:
# - 修复: [核心修复] 解决了在现代系统上编译旧版 OpenSSL (1.0.1a) 时，
#   因默认 gcc 版本过新而导致编译 silently fail (静默失败) 并使脚本中止的问题。
# - 变更: 在编译 OpenSSL 的步骤中，通过 `export CC=gcc-9` 明确指定使用
#   兼容的旧版本 C 编译器。
# - 变更: 安装编译器步骤现在会确保 `gcc-9` 和 `g++-9` 都被安装。
# ==============================================================================
#
# 功能特性:
# - [v4.1+] 强制使用 gcc-9 编译旧版 OpenSSL，解决兼容性问题。
# - [v4.0+] 自动编译并链接所需的旧版本 OpenSSL (1.0.1a)。
# - [v4.0+] 智能检查，避免重复安装。
# - [v4.0+] 通过运行程序本身来验证安装成功。
# - [v3.3+] 自动切换为国内高速 APT 镜像源。
# - [v3.1+] 自动检查并安装缺失的旧版本编译器 (g++-9, gcc-9)。
# - 智能检测 NVIDIA 驱动、CUDA 工具包及 GPU 计算能力。
# - 自动修复源代码中的 C++ 兼容性错误。
#

# --- 配置信息 ---
SCRIPT_VERSION="4.1.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
COMPATIBLE_COMPILERS=("g++-9" "g++-8" "g++-7")
COMPATIBLE_C_COMPILER="gcc-9"
OPENSSL_VERSION="1.0.1a"
OPENSSL_URL="http://www.openssl.org/source/old/1.0.1/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_INSTALL_PATH="/opt/openssl-${OPENSSL_VERSION}"

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

# 切换为国内镜像源
switch_to_domestic_apt_source() {
    log_info "为了确保安装过程顺利，将永久切换为国内高速镜像源 (清华大学 Tuna 源)。"
    
    local codename
    if ! codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); then
        log_error "无法自动检测 Ubuntu 系统代号。脚本无法继续。"
    fi
    log_info "检测到系统代号为: $codename"
    
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
# 由 VanitySearch 安装脚本 (v${SCRIPT_VERSION}) 生成
# 镜像源: 清华大学 (Tuna)
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
    
    sudo mkdir -p /etc/apt/sources.list.d
    sudo rm -f /etc/apt/sources.list.d/*

    log_success "已成功切换到国内镜像源。"
    
    log_info "正在使用新的国内镜像源执行 apt update..."
    if ! sudo apt-get update; then
        log_error "'apt update' 在使用国内镜像源时失败。请检查您的网络连接或DNS设置。"
    fi
    log_success "APT 更新成功！"
}

# 从源码安装旧版本 OpenSSL
install_openssl_from_source() {
    log_info "正在检查是否需要安装旧版本 OpenSSL (${OPENSSL_VERSION})..."
    if [ -f "${OPENSSL_INSTALL_PATH}/bin/openssl" ]; then
        log_success "旧版本 OpenSSL 已安装在 ${OPENSSL_INSTALL_PATH}。"
        return
    fi

    log_warn "未找到所需的旧版本 OpenSSL。现在将从源码编译安装..."
    log_info "这可能需要几分钟时间。"

    local build_dir; build_dir=$(mktemp -d)
    
    log_info "正在安装 OpenSSL 编译依赖 (wget)..."
    sudo apt-get install -y wget
    
    log_info "正在从 ${OPENSSL_URL} 下载源码..."
    wget -qO- "$OPENSSL_URL" | tar xz -C "$build_dir"
    
    cd "${build_dir}/openssl-${OPENSSL_VERSION}"
    
    log_info "指定使用 ${COMPATIBLE_C_COMPILER} 编译器以确保兼容性..."
    export CC=$(command -v ${COMPATIBLE_C_COMPILER})
    
    log_info "正在配置 OpenSSL..."
    ./config shared --prefix="$OPENSSL_INSTALL_PATH"
    
    log_info "正在编译 OpenSSL..."
    make -j$(nproc)
    
    log_info "正在安装 OpenSSL 到 ${OPENSSL_INSTALL_PATH}..."
    sudo make install > /dev/null
    
    # 清理
    cd /
    rm -rf "$build_dir"
    
    log_success "旧版本 OpenSSL (${OPENSSL_VERSION}) 已成功安装！"
}


# 查找或安装兼容的 g++/gcc 编译器
find_or_install_compiler() {
    local cpp_compiler_to_install="${COMPATIBLE_COMPILERS[0]}"
    log_info "正在查找兼容的 C++ 编译器 (${cpp_compiler_to_install}) 和 C 编译器 (${COMPATIBLE_C_COMPILER})..."
    
    local needs_install=false
    if ! command -v "$cpp_compiler_to_install" &>/dev/null; then
        log_warn "未找到 C++ 编译器: ${cpp_compiler_to_install}"
        needs_install=true
    fi
    if ! command -v "$COMPATIBLE_C_COMPILER" &>/dev/null; then
        log_warn "未找到 C 编译器: ${COMPATIBLE_C_COMPILER}"
        needs_install=true
    fi

    if [ "$needs_install" = true ]; then
        log_info "脚本将自动安装缺失的编译器..."
        if ! sudo apt-get install -y "$cpp_compiler_to_install" "$COMPATIBLE_C_COMPILER" build-essential; then
            log_error "自动安装编译器失败。请检查 APT 日志。"
        fi
        log_success "成功安装所需的编译器。"
    else
        log_success "已找到所有必需的兼容编译器。"
    fi
    
    DETECTED_CXXCUDA=$(command -v "$cpp_compiler_to_install")
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
        sudo rm -rf "$PROJECT_DIR"
    fi

    if ! git clone --quiet "$GITHUB_REPO"; then
        log_error "Git 克隆仓库失败。请检查网络连接或仓库地址是否正确。"
    fi
    
    log_success "源代码下载成功。"
    cd "$PROJECT_DIR"
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
    log_info "开始编译 (链接到自定义 OpenSSL)... 这可能需要几分钟时间。"
    
    local CFLAGS="-I${OPENSSL_INSTALL_PATH}/include"
    local LDFLAGS="-L${OPENSSL_INSTALL_PATH}/lib -Wl,-rpath,${OPENSSL_INSTALL_PATH}/lib"

    make clean > /dev/null 2>&1 || true
    
    if make -j$(nproc) gpu=1 ccap=${DETECTED_CCAP} all CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"; then
        log_success "编译成功完成！"
    else
        log_error "编译失败。请检查上方的详细编译日志以获取线索。"
    fi
}

# 验证安装
validate_installation() {
    log_info "正在进行最终验证..."
    if [ ! -x "./VanitySearch" ]; then
        log_error "验证失败：未找到可执行文件 'VanitySearch'。"
    fi
    
    log_info "执行 './VanitySearch -h' 以确认程序可运行..."
    echo "------------------- VanitySearch 帮助信息 -------------------"
    ./VanitySearch -h
    echo "----------------------------------------------------------"
    
    if [ $? -eq 0 ]; then
        log_success "验证成功！程序可以正常执行。"
    else
        log_error "验证失败！程序执行时返回了错误码。"
    fi
}

# --- 主执行逻辑 ---
main() {
    local start_dir; start_dir=$(pwd)
    
    echo -e "${C_BOLD}--- alek76-2/VanitySearch 自动化安装脚本 (v${SCRIPT_VERSION}) ---${C_RESET}"
    
    if [ -f "${start_dir}/${PROJECT_DIR}/VanitySearch" ] && "${start_dir}/${PROJECT_DIR}/VanitySearch" -h > /dev/null 2>&1; then
        log_success "VanitySearch 似乎已经成功安装并且可以运行。"
        log_info "可执行文件位于: ${C_BOLD}${start_dir}/${PROJECT_DIR}/VanitySearch${C_RESET}"
        log_info "如需重新安装，请先删除 '${PROJECT_DIR}' 目录后再次运行此脚本。"
        exit 0
    fi
    
    echo -e "此版本将自动安装旧版依赖并编译程序。"
    echo "----------------------------------------------------"
    sleep 2

    switch_to_domestic_apt_source
    find_or_install_compiler
    install_openssl_from_source
    check_nvidia_cuda
    download_source
    patch_source_code
    configure_makefile
    compile_source
    validate_installation
    
    cd "$start_dir"

    echo "----------------------------------------------------"
    log_success "VanitySearch 已成功安装并验证！"
    log_info "可执行文件位于: ${C_BOLD}${start_dir}/${PROJECT_DIR}/VanitySearch${C_RESET}"
    log_info "您可以像这样进入目录并运行它:"
    echo -e "  ${C_YELLOW}cd ${PROJECT_DIR}${C_RESET}"
    echo -e "  ${C_YELLOW}./VanitySearch --help${C_RESET} # 查看所有选项"
    echo ""
    log_warn "安全提醒: 请务必小心处理您生成的私钥。将其离线、安全地备份。"
    echo "----------------------------------------------------"
}

# 运行主函数
main
