#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 透明安装脚本 (v11.0 - 诊断增强版)                          ==
# ===================================================================================
# ==  作者: Kilo Code (经 Gemini AI 重构与增强)                                  ==
# ==  此版本修复了导致最终诊断报告被跳过的致命逻辑错误。                          ==
# ==  新增了内存检查和 OOM Killer 日志分析指南，专注于解决资源受限环境下的部署问题。==
# ===================================================================================

# --- 全局变量与函数定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 错误: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}[!] 警告: ${1}${NC}"; }

check_success() {
    if [ $1 -eq 0 ]; then
        print_success "$2"
    else
        print_error "$2 (退出码: $1)"
    fi
}

# ==============================================================================
# == 步骤 0-3 (保持不变，确保基础环境就绪)
# ==============================================================================
# (为简洁起见，此处省略前三个步骤的代码，它们与 v10.2 版本相同)
print_step "步骤 0/5：环境准备与依赖安装"
sudo apt-get update >/dev/null
check_success $? "更新软件包列表"
export DEBIAN_FRONTEND=noninteractive
sudo debconf-set-selections <<< "keyboard-configuration keyboard-configuration/layoutcode string us"
sudo apt-get install -y psmisc wget curl net-tools expect >/dev/null
check_success $? "安装基础工具"

print_step "步骤 1/5：安装 VNC 服务器和 XFCE 桌面"
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator >/dev/null
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
vncserver :1 -localhost no >/dev/null
check_success $? "启动 VNC 服务器 (:1)"

print_step "步骤 2/5：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
sudo apt-get install -y $GUACD_DEPS >/dev/null
check_success $? "安装 guacd 编译依赖项"
GUAC_VERSION="1.5.5"
wget -q "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
tar -xzf guacamole-server.tar.gz && cd "guacamole-server-${GUAC_VERSION}"
./configure --with-systemd-dir=/etc/systemd/system >/dev/null && make >/dev/null && sudo make install >/dev/null && sudo ldconfig
check_success $? "编译并安装 guacd"
cd ..
sudo /usr/local/sbin/guacd
check_success $? "启动 guacd 守护进程"

print_step "步骤 3/5：安装 Tomcat 10 并配置 Guacamole Web 应用"
sudo apt-get install -y default-jdk tomcat10 >/dev/null
check_success $? "安装 default-jdk 和 tomcat10"
TOMCAT_SERVICE="tomcat10"
TOMCAT_WEBAPPS_DIR="/var/lib/tomcat10/webapps"
TOMCAT_USER="tomcat"
TOMCAT_HOME="/usr/share/tomcat10"
wget -q "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
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
# == 第四部分：启动与验证 (核心逻辑重构)
# ==============================================================================
print_step "步骤 4/5：启动 Tomcat 并验证部署"
DEPLOYMENT_SUCCESS=false

print_info "正在尝试启动 Tomcat 服务..."
# 确保权限正确，然后以 tomcat 用户身份启动
sudo pkill -9 -f "org.apache.catalina.startup.Bootstrap" || true; sleep 2
sudo chown -R ${TOMCAT_USER}:${TOMCAT_USER} ${TOMCAT_HOME}
sudo -u ${TOMCAT_USER} ${TOMCAT_HOME}/bin/startup.sh
check_success $? "执行 Tomcat 启动命令"

print_info "等待 20 秒，以便 Tomcat 进行初始化 (在低资源服务器上可能需要更长时间)..."
sleep 20

print_info "正在检查 Tomcat 进程是否仍在运行..."
if pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null; then
    print_success "Tomcat Java 进程正在运行。"
    print_info "正在尝试通过 HTTP 连接到 Guacamole..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 http://localhost:8080/guacamole/)
    if [ "$HTTP_CODE" -eq 200 ]; then
        print_success "验证成功！Guacamole 登录页面已在 /guacamole/ 上线。"
        DEPLOYMENT_SUCCESS=true
        URL_PATH="/guacamole/"
    else
        print_warning "在 /guacamole/ 路径验证失败 (HTTP 状态码: $HTTP_CODE)。"
        # 即使失败，也继续执行诊断，不再尝试部署为 ROOT
    fi
else
    print_warning "Tomcat Java 进程未能保持运行状态！这极有可能是因为内存不足被系统终止。"
fi

# ==============================================================================
# == 第五部分：最终诊断报告 (现在总会执行)
# ==============================================================================
print_step "步骤 5/5：安装完成！最终诊断报告"

if [ "$DEPLOYMENT_SUCCESS" = true ]; then
    FINAL_URL="http://<您的公网IP>:8080${URL_PATH}"
    print_success "Guacamole 环境已安装和配置完毕。"
    echo -e "\n${BLUE}========================= 访问凭据 ==========================${NC}"
    echo -e "  ${YELLOW}Guacamole URL: ${GREEN}${FINAL_URL}${NC}"
    echo -e "  ${YELLOW}用户名:          ${GREEN}guacadmin${NC}"
    echo -e "  ${YELLOW}密码:            ${GREEN}${GUAC_PASS}${NC}"
    echo -e "${BLUE}=============================================================${NC}"
else
    print_warning "自动化部署验证失败！请仔细检查下面的诊断信息以找出问题根源。"
fi

echo -e "\n${BLUE}======================= 详细诊断检查 ==========================${NC}"
# 1. 内存与 OOM Killer 检查 (最重要)
echo -e "${YELLOW}--- 1. 系统资源与 OOM Killer 分析 ---${NC}"
echo "[i] 当前系统内存使用情况:"
free -h
echo ""
print_info "请重点关注 'available' (可用) 内存。如果低于 200-300MB，Tomcat 启动失败的风险极高。"
print_info "要确认是否是 OOM Killer 导致的问题，请在脚本执行后，手动运行以下命令检查内核日志:"
echo -e "${GREEN}    dmesg | grep -i 'killed process'${NC}"
print_warning "如果上述命令有输出 (特别是包含 'java' 或 'tomcat' 的行)，则 99% 的原因是内存不足。"

# 2. 核心进程与端口检查
echo -e "\n${YELLOW}--- 2. 核心进程与端口状态 ---${NC}"
pgrep -f "org.apache.catalina.startup.Bootstrap" &>/dev/null && print_success "Tomcat (Java) 进程正在运行。" || print_warning "Tomcat (Java) 进程未运行！"
netstat -tuln | grep -q ':8080' &>/dev/null && print_success "端口 8080 (Tomcat) 正在监听。" || print_warning "端口 8080 (Tomcat) 未监听！(这是 Tomcat 启动失败的直接证据)"
pgrep guacd &>/dev/null && print_success "guacd 进程正在运行。" || print_warning "guacd 进程未运行！"
netstat -tuln | grep -q ':4822' &>/dev/null && print_success "端口 4822 (guacd) 正在监听。" || print_warning "端口 4822 (guacd) 未监听！"
pgrep -f "Xtigervnc :1" &>/dev/null && print_success "VNC (Xtigervnc) 进程正在运行。" || print_warning "VNC (Xtigervnc) 进程未运行！"
netstat -tuln | grep -q ':5901' &>/dev/null && print_success "端口 5901 (VNC) 正在监听。" || print_warning "端口 5901 (VNC) 未监听！"

# 3. 文件系统和权限检查
echo -e "\n${YELLOW}--- 3. 目录与 Web 应用部署状态 ---${NC}"
echo "[i] Tomcat Web 应用目录 (${TOMCAT_WEBAPPS_DIR}) 内容:"
sudo ls -lA ${TOMCAT_WEBAPPS_DIR}/
if [ -d "${TOMCAT_WEBAPPS_DIR}/guacamole" ]; then
    print_success "Tomcat 已成功解压 guacamole.war 文件。"
elif [ -f "${TOMCAT_WEBAPPS_DIR}/guacamole.war" ]; then
    print_warning "Tomcat 未能解压 .war 文件！这通常是因为进程在解压完成前就被终止了。"
else
    print_warning ".war 文件不存在于 webapps 目录中。"
fi

# 4. 关键日志审查
echo -e "\n${YELLOW}--- 4. Tomcat 日志 (catalina.out) 审查 ---${NC}"
TOMCAT_LOG="${TOMCAT_HOME}/logs/catalina.out"
if [ -f "${TOMCAT_LOG}" ]; then
    echo "[i] 显示日志文件 '${TOMCAT_LOG}' 的最后 20 行:"
    echo -e "${GREEN}------------------------- LOG START -------------------------${NC}"
    sudo tail -n 20 "${TOMCAT_LOG}"
    echo -e "${GREEN}-------------------------- LOG END --------------------------${NC}"
else
    print_warning "找不到 Tomcat 日志文件！这强烈表明 Tomcat 从未成功启动到可以写入日志的阶段。"
fi

echo -e "\n${BLUE}======================= 最终结论与建议 ==========================${NC}"
if ! pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null && ! netstat -tuln | grep -q ':8080'; then
    echo -e "${RED}[结论] 主要怀疑是 **内存不足 (OOM Killer)** 导致 Tomcat 启动后立即被系统杀死。"
    echo -e "${YELLOW}[建议] 1. 请立刻运行 'dmesg | grep -i \"killed process\"' 命令进行确认。"
    echo -e "${YELLOW}       2. 如果确认是内存问题，唯一的解决方案是：**增加服务器的内存** (例如从 1GB 升级到 2GB)。"
    echo -e "${YELLOW}       3. 如果您无法增加内存，可以尝试先停止桌面环境 (`vncserver -kill :1`)，然后手动重启 Tomcat (`sudo -u tomcat /usr/share/tomcat10/bin/startup.sh`)，看是否能单独运行。"
else
    echo -e "${YELLOW}[结论] Tomcat 进程仍在运行，但 Web 应用无响应。问题可能出在 Guacamole 的配置或与 guacd 的通信上。"
    echo -e "${YELLOW}[建议] 1. 仔细检查上面的 Tomcat 日志，寻找 'SEVERE' 或 'Exception' 错误。"
    echo -e "${YELLOW}       2. 检查 /etc/guacamole 目录的权限和文件内容是否正确。"
fi

echo -e "\n${GREEN}诊断完成。${NC}"
