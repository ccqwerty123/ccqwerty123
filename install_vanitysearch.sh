#!/bin/bash
#
# alek76-2/VanitySearch 自动化安装与编译脚本 (中文增强版)
#
# 版本: 3.3.0-zh
#
# 此脚本专为通过管道执行而设计，例如:
# curl -sSL [URL] | bash
#
# ==============================================================================
# v3.3.0 更新日志:
# - 核心变更: 采用全新的"直接替换软件源"策略，以应对复杂的网络和系统配置问题。
# - 新增: 自动备份用户原始的 APT 源配置到一个临时目录。
# - 新增: 根据检测到的 Ubuntu 系统代号, 动态生成一份仅包含国内镜像
#   (清华大学 Tuna 源) 的临时 sources.list 文件。
# - 强化: 依然使用 'trap' 机制确保无论脚本如何退出，用户的原始软件源配置
#   都将被完美恢复，保障系统安全。
# - 移除: 移除了 v3.2 中的诊断和逐个禁用逻辑，改为更高效、更直接的整体替换。
# ==============================================================================
#
# 功能特性:
# - [v3.3+] 自动备份并临时替换为国内高速 APT 镜像源。
# - [v3.1+] 自动检查并尝试安装缺失的旧版本编译器 (g++-9)。
# - 智能检测 NVIDIA 驱动和 CUDA 工具包及 GPU 计算能力。
# - 自动修复源代码中的 C++ 兼容性错误。
# - 自动配置 Makefile 文件并编译。
# - 提供彩色的、详细的中文输出。
#

# --- 配置信息 ---
SCRIPT_VERSION="3.3.0-zh"
GITHUB_REPO="https://github.com/alek76-2/VanitySearch.git"
PROJECT_DIR="VanitySearch"
COMPATIBLE_COMPILERS=("g++-9" "g++-8" "g++-7")
APT_BACKUP_DIR="" # 用于记录 APT 备份目录

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

# 恢复被备份的 APT 源配置。此函数由 trap 调用，确保总能执行。
cleanup_apt_sources() {
    if [ -n "$APT_BACKUP_DIR" ] && [ -d "$APT_BACKUP_DIR" ]; then
        log_info "正在恢复原始的 APT 软件源配置..."
        # 强制删除临时创建的源文件和目录
        sudo rm -f /etc/apt/sources.list
        sudo rm -rf /etc/apt/sources.list.d
        # 恢复备份
        if [ -f "$APT_BACKUP_DIR/sources.list" ]; then
            sudo mv "$APT_BACKUP_DIR/sources.list" /etc/apt/
        fi
        if [ -d "$APT_BACKUP_DIR/sources.list.d" ]; then
            sudo mv "$APT_BACKUP_DIR/sources.list.d" /etc/apt/
        fi
        # 清理备份目录
        sudo rm -rf "$APT_BACKUP_DIR"
        log_success "原始 APT 源配置已恢复。"
        # 再次更新以使原始配置生效
        log_info "正在使用恢复后的源配置执行一次 apt update..."
        sudo apt-get update || log_warn "使用原始配置更新时出现问题，这可能是正常现象。"
    fi
}

# 设置 trap，无论脚本如何退出，都执行 cleanup_apt_sources 函数
trap cleanup_apt_sources EXIT

# 临时替换为国内镜像源
override_apt_sources() {
    log_info "为了确保安装过程顺利，将临时替换为国内高速镜像源 (清华大学 Tuna 源)。"
    
    # 1. 创建备份目录
    APT_BACKUP_DIR=$(mktemp -d /tmp/apt_backup_XXXXXX)
    log_info "原始 APT 配置将被备份到: $APT_BACKUP_DIR"
    
    # 2. 备份原始配置
    if [ -f "/etc/apt/sources.list" ]; then
        sudo mv /etc/apt/sources.list "$APT_BACKUP_DIR/"
    fi
    if [ -d "/etc/apt/sources.list.d" ]; then
        sudo mv /etc/apt/sources.list.d "$APT_BACKUP_DIR/"
    fi
    log_success "原始 APT 配置已备份。"

    # 3. 获取系统代号
    local codename
    if ! codename=$(. /etc/os-release && echo "$VERSION_CODENAME"); then
        log_error "无法自动检测 Ubuntu 系统代号。脚本无法继续。"
    fi
    log_info "检测到系统代号为: $codename"
    
    # 4. 创建新的 sources.list 文件
    log_info "正在生成新的 sources.list 文件..."
    sudo tee /etc/apt/sources.list > /dev/null <<EOF
# 由 VanitySearch 安装脚本 (v${SCRIPT_VERSION}) 临时生成
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
    
    # 确保 sources.list.d 目录存在
    sudo mkdir -p /etc/apt/sources.list.d

    log_success "已成功切换到国内镜像源。"
    
    # 5. 使用新源进行更新
    log_info "正在使用新的国内镜像源执行 apt update..."
    if ! sudo apt-get update; then
        log_error "'apt update' 在使用国内镜像源时失败。请检查您的网络连接或DNS设置。"
    fi
    log_success "APT 更新成功！"
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


# (其他辅助函数，如 check_nvidia_cuda, download_source, patch_source_code 等保持不变)
# ... [此处省略与 v3.2 版本相同的辅助函数代码以保持简洁] ...
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

    for ((i=1; i<=3; i++)); do
        if git clone --quiet "$GITHUB_REPO"; then
            log_success "源代码下载成功。"
            cd "$PROJECT_DIR"
            return
        fi
        log_warn "Git 克隆失败 (尝试 $i/3)。3 秒后重试..."
        sleep 3
    done
    
    log_error "尝试 3 次后，克隆仓库失败。"
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
    echo -e "此版本将自动备份并临时替换为${C_YELLOW}国内高速 APT 镜像源${C_RESET}以确保安装成功。"
    echo "----------------------------------------------------"
    sleep 2

    # 步骤 1: 临时替换为国内镜像源 (新增的关键步骤)
    override_apt_sources

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
