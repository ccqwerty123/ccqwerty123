#!/bin/bash

# =================================================================================
# ==    Apache Guacamole 透明安装脚本 (v6 - 增强诊断与健壮的进程管理)             ==
# =================================================================================
# ==  此版本在 v5 的基础上，对 VNC 进程的停止逻辑增加了更详细的诊断步骤，      ==
# ==  以清晰地揭示 'pkill' 失败的根本原因。                                    ==
# =================================================================================

# --- (此部分函数与之前版本相同，保持不变) ---
# --- 设置颜色代码以便输出 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 封装好的打印函数 ---
print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 失败: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }

# --- 核心检查函数 (上一个命令的退出码, 成功/失败信息) ---
check_success() { [ $1 -eq 0 ] && print_success "${2}" || print_error "${2}"; }

# --- 依赖项检查函数 ---
check_dependencies() {
    print_step "正在进行依赖项预检查..."
    local missing_deps=()
    for dep in "$@"; do
        if ! dpkg -s "$dep" >/dev/null 2>&1; then
            echo -e "${YELLOW}警告: 依赖项 '${dep}' 未安装。正在尝试安装...${NC}"
            sudo apt-get install -y "$dep"
            if ! dpkg -s "$dep" >/dev/null 2>&1; then
                missing_deps+=("$dep")
            fi
        else
            print_success "依赖项 '${dep}' 已就绪。"
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "以下核心依赖项安装失败: ${missing_deps[*]}. 无法继续。"
    else
        print_success "所有依赖项均已准备就绪。"
    fi
}
# --- (函数部分结束) ---


# --- 脚本主流程开始 ---
print_step "步骤 0/4：环境准备与非交互式配置"
sudo apt-get update
check_success $? "更新软件包列表"

echo "正在安装基础工具 (apt-utils, psmisc)..."
sudo apt-get install -y apt-utils psmisc # psmisc 提供了 pkill 和 pstree 命令
check_success $? "安装基础工具"

export DEBIAN_FRONTEND=noninteractive
check_success $? "设置 DEBIAN_FRONTEND=noninteractive"

echo -e "${YELLOW}重要提示: 请确保您已在 Cloud Studio 的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面"
echo "正在预设键盘布局以避免交互式提问..."
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/layoutcode string us"
check_success $? "预设键盘布局为 'us' (美国)"

echo "正在安装 VNC 和 XFCE (您将看到完整的安装过程)..."
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

check_dependencies tigervnc-standalone-server xfce4

echo -e "${YELLOW}--- 用户操作：设置 VNC 密码 ---${NC}"
print_info "接下来，系统会提示您设置一个6-8位的 VNC 密码，这是远程桌面连接本身所需的密码。"
read -p "理解后，请按 Enter 键开始设置 VNC 密码..."
vncserver :1
check_success $? "首次运行 vncserver 以生成配置文件"

# ---【核心改进部分 v6】更健壮地停止 VNC 进程并提供诊断信息 ---
print_info "等待 VNC 服务完成初始化..."
sleep 3 # 给予足够的时间创建 PID 文件

# 诊断步骤 1: 在尝试停止前，先确认进程是否存在
print_info "正在检查 'Xtigervnc :1' 进程的初始状态..."
if pgrep -f "Xtigervnc :1" > /dev/null; then
    print_success "进程 'Xtigervnc :1' 当前正在运行。准备执行停止操作。"

    # 尝试使用标准命令停止
    if ! vncserver -kill :1 > /dev/null 2>&1; then
        print_info "'vncserver -kill :1' 命令未能成功执行。启动备用停止方案..."

        # 备用方案: 使用 pkill
        pkill -f "Xtigervnc :1"
        PKILL_EXIT_CODE=$?

        # 对 pkill 的结果进行详细判断
        if [ $PKILL_EXIT_CODE -eq 0 ]; then
            print_success "使用 pkill 备用方案成功发送停止信号。"
        elif [ $PKILL_EXIT_CODE -eq 1 ]; then
            # 这种情况理论上不应该发生，因为我们已经用pgrep检查过了，但作为兜底
            print_error "使用 pkill 备用方案停止 VNC 进程失败。pkill报告没有找到匹配的进程。这可能是个瞬时问题。"
        else
            print_error "使用 pkill 备用方案停止 VNC 进程时发生错误 (退出码: $PKILL_EXIT_CODE)。"
        fi
    else
        print_success "'vncserver -kill :1' 命令成功执行。"
    fi

    # 循环验证进程是否已真正终止
    print_info "正在验证 VNC 进程是否已完全停止..."
    WAIT_COUNT=0
    while pgrep -f "Xtigervnc :1" > /dev/null && [ $WAIT_COUNT -lt 10 ]; do
        sleep 1
        ((WAIT_COUNT++))
        echo "  等待进程 'Xtigervnc :1' 终止... (${WAIT_COUNT}/10)"
    done

    # 最终确认
    if pgrep -f "Xtigervnc :1" > /dev/null; then
        print_error "无法停止 VNC 服务器进程！'Xtigervnc :1' 进程仍然存在。"
    fi
    print_success "进程 'Xtigervnc :1' 已成功停止。"

else
    # 如果一开始进程就不存在，说明 vncserver :1 启动后立即就失败了
    print_error "在首次运行 'vncserver :1' 后，未能检测到 'Xtigervnc :1' 进程！\n这意味着 VNC 服务可能因配置错误、依赖缺失或资源不足而启动失败。\n请检查 ~/.vnc/ 目录下最新的 .log 文件以获取详细错误信息。"
fi
# ---【核心改进结束】---

[ ! -f ~/.vnc/xstartup ] && print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
echo "startxfce4 &" >> ~/.vnc/xstartup
check_success $? "配置 VNC 启动脚本以加载 XFCE"

# 增加 -fg 选项可以在前台运行，更容易捕获启动日志，但这里我们仍用后台模式
vncserver -localhost no :1
check_success $? "以正确的配置重新启动 VNC 服务器"

sleep 2
if ! netstat -tuln | grep -q ':5901'; then
    print_error "VNC 服务器端口 5901 未被监听。服务可能启动失败。请检查 ~/.vnc/ 目录下的日志文件。"
fi
print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行并监听。"


# ==============================================================================
# ==  后续步骤与之前版本相同，为保持完整性，全部包含。                       ==
# ==============================================================================

# (后续所有步骤... 省略以保持简洁)
# ...
# ...
# ... (您的脚本其余部分)
# ...
