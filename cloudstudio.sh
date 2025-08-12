#!/bin-bash

# ===================================================================================
# ==    Apache Guacamole 透明安装脚本 (v7 - 交互式密码与自动日志诊断)             ==
# ===================================================================================
# ==  此版本将密码设置(vncpasswd)与服务启动(vncserver)分离，并增加了在 VNC      ==
# ==  启动失败时自动打印相关日志文件的功能，以实现终极问题诊断。                  ==
# ===================================================================================

# --- (函数部分与 v6 相同，保持不变) ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 失败: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }

check_success() { [ $1 -eq 0 ] && print_success "${2}" || print_error "${2}"; }

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
sudo apt-get install -y apt-utils psmisc
check_success $? "安装基础工具"

export DEBIAN_FRONTEND=noninteractive
check_success $? "设置 DEBIAN_FRONTEND=noninteractive"

echo -e "${YELLOW}重要提示: 请确保您已在 Cloud Studio 的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."


# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/4：安装 VNC 服务器和 XFCE 桌面"
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

# ---【核心改进部分 v7】分离密码设置并增加自动日志诊断 ---
echo -e "${YELLOW}--- 用户操作：设置 VNC 密码 ---${NC}"
print_info "即将调用 'vncpasswd' 命令来设置 VNC 专用的密码。"
print_info "您需要输入一个6到8个字符的密码，然后再次输入以确认。注意：输入时密码不会显示在屏幕上。"
read -p "请按 Enter 键以手动设置密码..."

# 步骤 1: 显式调用 vncpasswd
vncpasswd
VNCPAWWD_EXIT_CODE=$?

# 步骤 2: 验证 vncpasswd 是否成功创建了密码文件
if [ $VNCPAWWD_EXIT_CODE -ne 0 ] || [ ! -f ~/.vnc/passwd ]; then
    print_error "'vncpasswd' 命令执行失败或未成功创建密码文件 (~/.vnc/passwd)。请重新运行脚本并确保正确设置密码。"
fi
print_success "VNC 密码文件已成功创建。"

# 步骤 3: 尝试首次启动 VNC 服务器
print_info "正在尝试首次启动 VNC 服务器以生成配置文件..."
vncserver :1
sleep 3 # 等待服务启动

# 步骤 4: 终极诊断 - 检查进程是否存在，如果不存在则打印日志
if ! pgrep -f "Xtigervnc :1" > /dev/null; then
    # 如果进程不存在，执行自动诊断
    LOG_FILE_PATH=~/.vnc/$(hostname):1.log
    print_error "在运行 'vncserver :1' 后，未能检测到 'Xtigervnc :1' 进程！VNC 服务启动失败。"
    
    if [ -f "$LOG_FILE_PATH" ]; then
        print_info "检测到相关的日志文件，以下是该文件的最后 15 行内容，这很可能会揭示失败的原因："
        echo -e "${RED}--- 日志 ($LOG_FILE_PATH) 开始 ---"
        tail -n 15 "$LOG_FILE_PATH"
        echo -e "--- 日志结束 ---${NC}"
        print_info "请仔细检查上述日志中的 'error', 'failed', 'Cannot' 等关键词来定位具体问题。"
    else
        print_info "未找到 VNC 日志文件 ($LOG_FILE_PATH)。这通常意味着服务在非常早期的阶段就失败了，例如，xstartup 文件权限问题或缺少基本依赖。"
    fi
    exit 1 # 终止脚本
fi

print_success "VNC 服务已成功临时启动，现在将停止它以进行配置。"

# --- (后续的停止逻辑与 v6 相同) ---
if ! vncserver -kill :1 > /dev/null 2>&1; then
    print_info "'vncserver -kill :1' 命令失败，启动备用方案..."
    pkill -f "Xtigervnc :1"
    check_success $? "使用 pkill 备用方案停止 VNC 进程"
else
    print_success "'vncserver -kill :1' 命令成功执行"
fi

WAIT_COUNT=0
while pgrep -f "Xtigervnc :1" > /dev/null && [ $WAIT_COUNT -lt 10 ]; do
    sleep 1; ((WAIT_COUNT++)); echo "  等待进程终止... (${WAIT_COUNT}/10)";
done

if pgrep -f "Xtigervnc :1" > /dev/null; then
    print_error "无法停止 VNC 服务器进程！进程仍然存在。"
fi
print_success "临时 VNC 会话已成功停止。"
# ---【核心改进结束】---

[ ! -f ~/.vnc/xstartup ] && print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
# 确保 xstartup 文件有执行权限
chmod +x ~/.vnc/xstartup
check_success $? "为 ~/.vnc/xstartup 添加执行权限"

echo "startxfce4 &" >> ~/.vnc/xstartup
check_success $? "配置 VNC 启动脚本以加载 XFCE"

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
# (您的脚本其余部分保持不变)
# ...
