#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 4.0.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v4.0.0 更新日志:
# - 新增: [核心功能] 自动从源码编译和安装旧版本 OpenSSL (1.0.1a) 到 /opt/ 目录，
#   以解决新版 OpenSSL 导致的私钥计算错误问题。
# - 新增: [智能判断] 脚本运行时会先检查 VanitySearch 是否已成功安装，
#   若已存在且可执行，则直接退出，实现重复执行无副作用 (幂等性)。
# - 新增: [可靠验证] 编译成功后，脚本会自动执行 "./VanitySearch -h" 命令并显示其输出，
#   以此作为最终的、可靠的成功验证。
# - 移除: 根据用户要求，移除了 APT 镜像源的备份与恢复逻辑，现在切换镜像源为永久性操作。
# - 优化: 编译步骤现在会通过 CFLAGS 和 LDFLAGS 明确链接到新安装的旧版 OpenSSL。
# ==============================================================================
#
# 功能特性:
# - [v4.0+] 自动编译并链接所需的旧版本 OpenSSL (1.0.1a)。
# - [v4.0+] 智能检查，避免重复安装。
# - [v4.0+] 通过运行程序本身来验证安装成功。
# - [v3.3+] 自动切换为国内高速 APT 镜像源。
# - [v3.1+] 自动检查并安装缺失的旧版本编译器 (g++-9)。
# - 智能检测 NVIDIA 驱动、CUDA 工具包及 GPU 计算能力。
# - 自动修复源代码中的 C++ 兼容性错误。
# - 自动配置 Makefile 文件并编译。
# - 提供彩色的、详细的中文输出。
#

# --- 配置信息 ---
SCRIPT_VERSION="4.0.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
COMPATIBLE_COMPILERS=("g++-9" "g++-8" "g++-7")
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
    
    # 获取系统代号
    local codename
    if ! codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); then
        log_error "无法自动检测 Ubuntu 系统代号。脚本无法继续。"
    fi
    log_info "检测到系统代号为: $codename"
    
    # 创建新的 sources.list 文件
    log_info "正在生成新的 sources.list 文件..."
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
# 由 VanitySearch 安装脚本 (v${SCRIPT_VERSION}) 生成
# 镜像源: 清华大学 (Tuna)
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename} main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename} main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-updates main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-updates main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-backports main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-backports main restricted universe multiverse
deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-security main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ ${codename}-security main restricted universe multiverse
EOF
    
    # 确保 sources.list.d 目录存在且清空
    sudo mkdir -p /etc/apt/sources.list.d
    sudo rm -f /etc/apt/sources.list.d/*

    log_success "已成功切换到国内镜像源。"
    
    # 使用新源进行更新
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
    
    # 安装编译依赖
    log_info "正在安装 OpenSSL 编译依赖 (build-essential, wget)..."
    sudo apt-get install -y build-essential wget
    
    log_info "正在从 ${OPENSSL_URL} 下载源码..."
    wget -qO- "$OPENSSL_URL" | tar xz -C "$build_dir"
    
    cd "${build_dir}/openssl-${OPENSSL_VERSION}"
    
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

    log_warn "未找到兼容的 g++ 编译器。脚本将自动安装 ${COMPATIBLE_COMPILERS[0]}。"
    log_info "正在执行安装命令..."
    if ! sudo apt-get install -y "${COMPATIBLE_COMPILERS[0]}"; then
        log_error "自动安装 ${COMPATIBLE_COMPILERS[0]} 失败。请检查 APT 日志。"
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
    
    # 定义指向旧版本 OpenSSL 的编译和链接标志
    local CFLAGS="-I${OPENSSL_INSTALL_PATH}/include"
    local LDFLAGS="-L${OPENSSL_INSTALL_PATH}/lib -Wl,-rpath,${OPENSSL_INSTALL_PATH}/lib"

    make clean > /dev/null 2>&1 || true
    
    # 在 make 命令中传入这些标志
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
    # 执行并显示帮助信息
    ./VanitySearch -h
    echo "----------------------------------------------------------"
    
    # 再次检查退出码
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
    
    # 步骤 0: 检查是否已安装 (幂等性)
    if [ -f "${PROJECT_DIR}/VanitySearch" ] && "${start_dir}/${PROJECT_DIR}/VanitySearch" -h > /dev/null 2>&1; then
        log_success "VanitySearch 似乎已经成功安装并且可以运行。"
        log_info "可执行文件位于: ${C_BOLD}${start_dir}/${PROJECT_DIR}/VanitySearch${C_RESET}"
        log_info "如需重新安装，请先删除 '${PROJECT_DIR}' 目录后再次运行此脚本。"
        exit 0
    fi
    
    echo -e "此版本将自动安装旧版依赖并编译程序。"
    echo "----------------------------------------------------"
    sleep 2

    # 步骤 1: 切换为国内镜像源
    switch_to_domestic_apt_source

    # 步骤 2: 安装旧版本 OpenSSL
    install_openssl_from_source

    # 步骤 3: 查找或安装兼容的编译器
    find_or_install_compiler

    # 步骤 4: 检查 NVIDIA 环境
    check_nvidia_cuda

    # 步骤 5: 下载源代码
    download_source

    # 步骤 6: 应用修复补丁
    patch_source_code

    # 步骤 7: 配置 Makefile
    configure_makefile

    # 步骤 8: 编译
    compile_source
    
    # 步骤 9: 验证
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
