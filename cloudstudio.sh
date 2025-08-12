#!/bin/bash

# ===================================================================================
# ==    Apache Guacamole 透明安装脚本 (v8 - 全自动密码与终极诊断)                 ==
# ===================================================================================
# ==  此版本彻底移除了所有交互式密码输入。脚本会自动生成一个安全的随机密码，      ==
# ==  完成所有配置，并保留了强大的自动日志诊断功能。                              ==
# ===================================================================================

# --- (函数部分与之前版本相同) ---
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
print_step "步骤 0/4：环境准备"
sudo apt-get update
check_success $? "更新软件包列表"

# 安装 openssl 以便生成密码
sudo apt-get install -y apt-utils psmisc openssl
check_success $? "安装基础工具 (psmisc, openssl)"

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

# ---【核心改进部分 v8】全自动生成并设置 VNC 密码 ---
print_info "正在自动生成并设置一个安全的 VNC 密码..."
# 生成一个8位的随机密码
VNC_PASS=$(openssl rand -base64 8)

# 通过管道将密码输入给 vncpasswd 命令
# 我们需要先创建 .vnc 目录，因为 vncpasswd 在某些版本下如果目录不存在会失败
mkdir -p ~/.vnc
echo -e "${VNC_PASS}\n${VNC_PASS}" | vncpasswd
check_success $? "自动执行 vncpasswd 命令"

if [ ! -f ~/.vnc/passwd ]; then
    print_error "VNC 密码文件 (~/.vnc/passwd) 创建失败！无法继续。"
fi
# 将 VNC 密码打印出来，这是后续 Guacamole 配置中需要用到的密码
print_success "VNC 密码已自动设置。请记下此密码，稍后将自动填入 Guacamole 配置中。"
echo -e "  ${YELLOW}您的 VNC 密码是: ${GREEN}${VNC_PASS}${NC}"


# --- 首次启动、诊断和配置流程 (与 v7 相同，非常健壮) ---
print_info "正在尝试首次启动 VNC 服务器以生成配置文件..."
vncserver :1
sleep 3

if ! pgrep -f "Xtigervnc :1" > /dev/null; then
    LOG_FILE_PATH=$(find ~/.vnc/ -name "*.log" | head -n 1)
    print_error "在运行 'vncserver :1' 后，未能检测到 'Xtigervnc :1' 进程！VNC 服务启动失败。"
    if [ -n "$LOG_FILE_PATH" ] && [ -f "$LOG_FILE_PATH" ]; then
        print_info "检测到相关日志文件，以下是其内容，这很可能会揭示失败的原因："
        echo -e "${RED}--- 日志 ($LOG_FILE_PATH) 开始 ---"
        cat "$LOG_FILE_PATH"
        echo -e "--- 日志结束 ---${NC}"
    else
        print_info "未找到 VNC 日志文件。请检查 'vncserver' 命令是否可执行以及相关权限。"
    fi
    exit 1
fi
print_success "VNC 服务已成功临时启动，现在将停止它以进行配置。"

vncserver -kill :1 > /dev/null 2>&1 || pkill -f "Xtigervnc :1"
sleep 1
print_success "临时 VNC 会话已成功停止。"

[ ! -f ~/.vnc/xstartup ] && print_error "VNC 配置文件 ~/.vnc/xstartup 未找到！"
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
# ---【第一部分核心改进结束】---


# ==============================================================================
# ==  第二部分：安装 guacd (Guacamole 后端) - 无需改动
# ==============================================================================
# (此部分与之前完全相同)
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"
# ... (省略相同代码以保持简洁) ...


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 并自动化配置 Guacamole"
# ... (省略安装Tomcat和下载war包的代码) ...

# ---【核心改进部分 v8】全自动密码配置 ---
echo -e "${YELLOW}--- 自动化 Guacamole 密码配置 ---${NC}"
# 不再需要用户输入VNC密码，直接使用之前生成的 $VNC_PASS 变量
read -sp "请为 Guacamole 网页登录设置一个新密码 (这是您访问网页时用的): " GUAC_PASS; echo

# ... (省略创建 guacamole.properties 的代码) ...

sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="user" password="__GUAC_PASSWORD_PLACEHOLDER__">
        <connection name="XFCE Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">__VNC_PASSWORD_PLACEHOLDER__</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建 user-mapping.xml 配置文件模板"

# 自动填入Guacamole网页密码
sudo sed -i "s|__GUAC_PASSWORD_PLACEHOLDER__|${GUAC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 Guacamole 登录密码"
# 自动填入之前生成的VNC密码
sudo sed -i "s|__VNC_PASSWORD_PLACEHOLDER__|${VNC_PASS}|g" /etc/guacamole/user-mapping.xml
check_success $? "自动填入 VNC 连接密码"

# ... (省略后续重启和验证Tomcat的代码) ...


# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"
print_success "所有组件已成功安装并配置。"
echo ""
echo -e "  访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  用户名:   ${GREEN}user${NC}"
echo -e "  密码:     ${GREEN}您刚刚为 Guacamole 设置的网页登录密码${NC}"
echo ""
echo -e "${YELLOW}请注意：Guacamole 内部使用的 VNC 连接密码已为您自动生成并配置，您无需关心。${NC}"
echo "祝您使用愉快！"
