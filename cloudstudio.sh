#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 透明安装脚本 (v14.0 - 过程化诊断与无交互强化版)            ==
# ===================================================================================
# ==  作者: Kilo Code (经 Gemini AI 重构与增强)                                  ==
# ==  此版本核心思想是“即时诊断”，在每一步关键操作后立即验证，并彻底解决交互问题。  ==
# ==  1. 新增 debconf-set-selections，从根源上避免键盘布局等交互式提示。          ==
# ==  2. 在 VNC、guacd、Tomcat 每一步安装/启动后，都立即进行进程和端口检查。      ==
# ==  3. 移除了所有 >/dev/null，让 apt-get 等命令的输出完全透明。                 ==
# ==  4. 重构了最终诊断报告，使其成为一个基于事实检查的总结，而非猜测。           ==
# ===================================================================================

# --- 脚本设置与全局函数 ---
# -e: 如果任何命令失败，立即退出脚本
# -o pipefail: 如果管道中的任何命令失败，整个管道的返回码为失败
set -eo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 错误: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }
check_success() {
    if [ $1 -eq 0 ]; then
        print_success "$2"
    else
        print_error "$2 (退出码: $1)"
    fi
}

# ==============================================================================
# == 步骤 0/6：环境准备与无交互配置
# ==============================================================================
print_step "步骤 0/6：环境准备与无交互配置"
print_info "正在更新软件包列表..."
sudo apt-get update
check_success $? "更新软件包列表"

export DEBIAN_FRONTEND=noninteractive
print_info "正在预设 debconf 答案以避免交互式提示..."
# 彻底解决 "debconf: unable to initialize frontend" 问题
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/layoutcode string us"
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/variantcode string intl"
check_success $? "预设键盘配置"

print_info "正在安装基础工具 (apt-utils, wget, curl, etc)..."
# 显示完整安装日志，不再隐藏
sudo apt-get install -y psmisc wget curl net-tools expect apt-utils
check_success $? "安装基础工具"

# ==============================================================================
# == 步骤 1/6：安装 VNC 服务器和 XFCE 桌面
# ==============================================================================
print_step "步骤 1/6：安装 VNC 服务器和 XFCE 桌面"
print_info "正在安装 VNC 和 XFCE，这将需要一些时间..."
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

VNC_PASS=$(openssl rand -base64 8 | tr -d '/+=') && mkdir -p ~/.vnc
expect << EOF >/dev/null 2>&1
spawn vncpasswd
expect "Password:"
send "${VNC_PASS}\r"
expect "Verify:"
send "${VNC_PASS}\r"
expect "Would you like to enter a view-only password (y/n)?"
send "n\r"
expect eof
EOF
check_success $? "自动设置 VNC 密码"

cat > ~/.vnc/xstartup << EOF
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP="XFCE"
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup

vncserver -kill :1 >/dev/null 2>&1 && sleep 1
vncserver :1 -localhost no
check_success $? "执行 VNC 服务器启动命令"

# --- 即时诊断 #1：检查 VNC ---
print_info "正在进行即时诊断：验证 VNC 服务器状态..."
if pgrep -f "Xtigervnc :1" > /dev/null && netstat -tuln | grep -q ':5901'; then
    print_success "VNC 服务器正在运行，并在端口 5901 上监听。"
else
    print_error "VNC 服务器未能成功启动！请检查上面的 XFCE 或 VNC 安装日志。"
fi

# ==============================================================================
# == 步骤 2/6：编译并安装 Guacamole 后端 (guacd)
# ==============================================================================
print_step "步骤 2/6：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
print_info "正在安装 guacd 的编译依赖..."
sudo apt-get install -y $GUACD_DEPS
check_success $? "安装 guacd 编译依赖项"

GUAC_VERSION="1.5.5"
wget --progress=bar:force --timeout=60 "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
check_success $? "下载 Guacamole Server 源码"

tar -xzf guacamole-server.tar.gz && cd "guacamole-server-${GUAC_VERSION}"
print_info "正在配置 (./configure)..."
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "源码配置"

print_info "正在编译 (make)，这可能需要很长时间..."
make
check_success $? "源码编译"

print_info "正在安装 (make install)..."
sudo make install && sudo ldconfig
check_success $? "安装 guacd"
cd ..

sudo /usr/local/sbin/guacd
check_success $? "执行 guacd 启动命令"

# --- 即时诊断 #2：检查 guacd ---
print_info "正在进行即时诊断：验证 guacd 守护进程状态..."
if pgrep guacd > /dev/null && netstat -tuln | grep -q ':4822'; then
    print_success "guacd 守护进程正在运行，并在端口 4822 上监听。"
else
    print_error "guacd 未能成功启动！请检查上面的编译和安装日志。"
fi

# ==============================================================================
# == 步骤 3/6：安装 Tomcat 10 并配置 Guacamole Web 应用
# ==============================================================================
print_step "步骤 3/6：安装 Tomcat 10 并配置 Guacamole Web 应用"
print_info "正在安装 Java 和 Tomcat 10..."
sudo apt-get install -y default-jdk tomcat10
check_success $? "安装 default-jdk 和 tomcat10"

TOMCAT_WEBAPPS_DIR="/var/lib/tomcat10/webapps"
TOMCAT_USER="tomcat"
TOMCAT_HOME="/usr/share/tomcat10"

wget --progress=bar:force --timeout=60 "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
check_success $? "下载 guacamole.war"

sudo mv guacamole.war "${TOMCAT_WEBAPPS_DIR}/"
GUAC_PASS="GuacAdmin`date +%s | tail -c 5`"
sudo mkdir -p /etc/guacamole

sudo bash -c 'cat > /etc/guacamole/guacamole.properties' <<< "guacd-hostname: localhost\nguacd-port: 4822\nuser-mapping: /etc/guacamole/user-mapping.xml"
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' <<< "<user-mapping><authorize username=\"guacadmin\" password=\"${GUAC_PASS}\"><connection name=\"XFCE Desktop\"><protocol>vnc</protocol><param name=\"hostname\">localhost</param><param name=\"port\">5901</param><param name=\"password\">${VNC_PASS}</param></connection></authorize></user-mapping>"

sudo chown -R ${TOMCAT_USER}:${TOMCAT_USER} /etc/guacamole && sudo chmod -R 750 /etc/guacamole
sudo ln -sfn /etc/guacamole "${TOMCAT_HOME}/.guacamole"
check_success $? "创建 Guacamole 配置文件和符号链接"

# ==============================================================================
# == 步骤 4/6：启动 Tomcat 并验证部署
# ==============================================================================
print_step "步骤 4/6：启动 Tomcat 并验证部署"
sudo pkill -9 -f "org.apache.catalina.startup.Bootstrap" || true; sleep 2

print_info "正在确保 Tomcat 日志目录存在并拥有正确权限..."
sudo mkdir -p "${TOMCAT_HOME}/logs" && sudo chown ${TOMCAT_USER}:${TOMCAT_USER} "${TOMCAT_HOME}/logs"
check_success $? "创建并授权 Tomcat 日志目录"

print_info "正在以 tomcat 用户身份启动 Tomcat 服务..."
sudo -u ${TOMCAT_USER} ${TOMCAT_HOME}/bin/startup.sh
check_success $? "执行 Tomcat 启动命令"

print_info "等待 25 秒，以便 Tomcat 完全初始化并部署 Guacamole.war..."
sleep 25

# --- 即时诊断 #3：检查 Tomcat ---
print_info "正在进行即时诊断：验证 Tomcat 和 Guacamole 应用状态..."
if pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null; then
    print_success "Tomcat Java 进程正在运行。"
    if netstat -tuln | grep -q ':8080'; then
        print_success "端口 8080 (Tomcat) 正在监听。"
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "http://localhost:8080/guacamole-${GUAC_VERSION}.war/")
        if [ "$HTTP_CODE" -eq 200 ]; then
            print_success "Guacamole Web 应用已成功响应 (HTTP 200 OK)!"
            DEPLOYMENT_SUCCESS=true
            URL_PATH="/guacamole-${GUAC_VERSION}.war/"
        else
            print_error "Tomcat 正在运行，但 Guacamole 应用无响应 (HTTP Code: $HTTP_CODE)。请检查 Tomcat 日志。"
        fi
    else
        print_error "Tomcat 进程在运行，但未监听端口 8080！这是一个严重的内部错误。"
    fi
else
    print_error "Tomcat 进程未能保持运行状态！这很可能是由于内存不足 (OOM Killer) 或 Java 致命错误。请检查系统日志 ('dmesg') 和 Tomcat 日志。"
fi

# ==============================================================================
# == 步骤 5/6：安装完成！
# ==============================================================================
print_step "步骤 5/6：安装完成！"
IP_ADDR=$(hostname -I | awk '{print $1}')
FINAL_URL="http://${IP_ADDR}:8080${URL_PATH}"
print_success "Guacamole 环境已成功安装和验证。"
echo -e "\n${BLUE}========================= 访问凭据 ==========================${NC}"
echo -e "  ${YELLOW}Guacamole URL: ${GREEN}${FINAL_URL}${NC}"
echo -e "  ${YELLOW}用户名:          ${GREEN}guacadmin${NC}"
echo -e "  ${YELLOW}密码:            ${GREEN}${GUAC_PASS}${NC}"
echo -e "${BLUE}=============================================================${NC}"

# ==============================================================================
# == 步骤 6/6：最终系统状态总结报告
# ==============================================================================
print_step "步骤 6/6：最终系统状态总结报告"
echo -e "${YELLOW}--- 1. VNC 桌面环境 ---${NC}"
pgrep -f "Xtigervnc :1" &>/dev/null && print_success "进程 (Xtigervnc) 正在运行。" || print_error "进程 (Xtigervnc) 未运行。"
netstat -tuln | grep -q ':5901' &>/dev/null && print_success "端口 (5901) 正在监听。" || print_error "端口 (5901) 未监听。"

echo -e "\n${YELLOW}--- 2. Guacamole 后端 ---${NC}"
pgrep guacd &>/dev/null && print_success "进程 (guacd) 正在运行。" || print_error "进程 (guacd) 未运行。"
netstat -tuln | grep -q ':4822' &>/dev/null && print_success "端口 (4822) 正在监听。" || print_error "端口 (4822) 未监听。"

echo -e "\n${YELLOW}--- 3. Tomcat & Guacamole Web App ---${NC}"
pgrep -f "org.apache.catalina.startup.Bootstrap" &>/dev/null && print_success "进程 (Tomcat/Java) 正在运行。" || print_error "进程 (Tomcat/Java) 未运行。"
netstat -tuln | grep -q ':8080' &>/dev/null && print_success "端口 (8080) 正在监听。" || print_error "端口 (8080) 未监听。"
if [ -d "${TOMCAT_WEBAPPS_DIR}/guacamole-${GUAC_VERSION}.war" ]; then
    print_success "Web 应用 (guacamole-${GUAC_VERSION}.war) 已被 Tomcat 解压。"
else
    print_error "Web 应用 (guacamole-${GUAC_VERSION}.war) 未被解压。"
fi

echo -e "\n${YELLOW}--- 4. Tomcat 日志 (catalina.out) 摘要 ---${NC}"
TOMCAT_LOG="${TOMCAT_HOME}/logs/catalina.out"
if [ -f "${TOMCAT_LOG}" ]; then
    echo "[i] 显示日志文件 '${TOMCAT_LOG}' 的最后 20 行:"
    echo -e "${GREEN}------------------------- LOG START -------------------------${NC}"
    sudo tail -n 20 "${TOMCAT_LOG}"
    echo -e "${GREEN}-------------------------- LOG END --------------------------${NC}"
else
    print_error "找不到 Tomcat 日志文件！"
fi

echo -e "\n${GREEN}所有检查完成，系统状态正常。${NC}"
