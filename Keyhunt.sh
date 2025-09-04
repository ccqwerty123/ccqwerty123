#!/bin/bash

# ==============================================================================
# Keyhunt 强大安装脚本
#
# 功能:
# 1. 检查并请求 Root 权限。
# 2. 检查是否为 Debian/Ubuntu 系统。
# 3. 自动检查并安装所需的依赖包。
# 4. 防止重复安装，并提供重新安装选项。
# 5. 克隆最新的代码仓库。
# 6. 尝试编译，如果主版本失败则自动尝试编译旧版 (legacy)。
# 7. 包含完整的错误处理机制。
# 8. 成功后显示帮助信息和安装路径。
# ==============================================================================

# --- 配置 ---
# 设置颜色，用于输出信息
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 软件源和目标目录
REPO_URL="https://github.com/albertobsd/keyhunt.git"
INSTALL_DIR="keyhunt"

# --- 函数定义 ---

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 1. 检查 Root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要 root 权限来安装依赖包。请使用 'sudo ./install_keyhunt.sh' 运行。"
    fi
}

# 2. 检查操作系统
check_os() {
    if ! [ -f /etc/debian_version ]; then
        log_warn "此脚本最适用于 Debian 系的 Linux (如 Debian, Ubuntu)。"
        read -p "您的系统可能不是 Debian 系，是否仍要继续？(y/n): " choice
        case "$choice" in
            y|Y ) log_info "继续执行...";;
            n|N ) log_error "安装已取消。";;
            * ) log_error "无效输入，安装已取消。";;
        esac
    fi
}

# 3. 检查并安装依赖
install_dependencies() {
    log_info "正在检查并安装依赖包..."
    
    # 更新 apt 缓存
    apt-get update -y || log_error "apt 更新失败，请检查您的软件源。"
    
    # 依赖列表
    local deps=("git" "build-essential" "libssl-dev" "libgmp-dev")
    local missing_deps=()

    for dep in "${deps[@]}"; do
        if ! dpkg -s "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_info "以下依赖将会被安装: ${missing_deps[*]}"
        apt-get install -y "${missing_deps[@]}" || log_error "依赖安装失败！"
        log_info "依赖安装完成。"
    else
        log_info "所有依赖均已安装。"
    fi
}

# --- 主程序 ---

main() {
    clear
    log_info "--- Keyhunt 自动安装脚本启动 ---"

    check_root
    check_os

    # 4. 检查是否已安装
    if [ -d "$INSTALL_DIR" ]; then
        log_warn "检测到 '$INSTALL_DIR' 目录已存在。"
        read -p "您是否希望删除旧目录并重新安装？(y/n): " reinstall_choice
        case "$reinstall_choice" in
            y|Y )
                log_info "正在删除旧的 '$INSTALL_DIR' 目录..."
                rm -rf "$INSTALL_DIR" || log_error "删除目录 '$INSTALL_DIR' 失败。"
                ;;
            n|N )
                log_info "安装已取消。您可手动进入 '$INSTALL_DIR' 目录进行操作。"
                exit 0
                ;;
            * )
                log_error "无效输入，安装已取消。"
                ;;
        esac
    fi

    install_dependencies

    # 5. 克隆代码仓库
    log_info "正在从 GitHub 克隆 Keyhunt..."
    git clone "$REPO_URL" || log_error "克隆代码仓库失败。请检查网络连接或 Git 配置。"
    
    # 切换到安装目录
    cd "$INSTALL_DIR" || log_error "进入目录 '$INSTALL_DIR' 失败。"

    # 6. 编译程序
    log_info "开始编译 Keyhunt..."
    if make; then
        log_info "主版本编译成功！"
    else
        log_warn "主版本编译失败，正在尝试编译旧版 (legacy)..."
        if make legacy; then
            log_info "旧版 (legacy) 编译成功！"
        else
            log_error "两种编译方式均失败。请检查编译环境和错误日志。"
        fi
    fi
    
    # 7. 安装成功
    clear
    log_info "--- Keyhunt 安装和编译成功！ ---"
    
    local final_path
    final_path=$(pwd)
    
    echo -e "\n${YELLOW}安装目录:${NC} $final_path"
    echo -e "\n${YELLOW}程序帮助信息如下:${NC}"
    
    # 8. 输出帮助信息
    ./keyhunt -h

    log_info "\n--- 安装完成 ---"
}

# 运行主函数
main
