#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 透明安装脚本 (v9.7 - 全方位修复与增强)                   ==
# ===================================================================================
# ==  作者: Kilo Code (经 Gemini AI 重构与增强)                                  ==
# ==  此版本全面修复了权限、服务管理、部署验证和诊断流程，                  ==
# ==  旨在解决 VNC 无画面、Guacamole 404 及在非 systemd 环境下的各种问题。     ==
# ===================================================================================

# --- 函数定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# --- 脚本主流程开始 ---
print_step "步骤 0/5：环境准备与依赖安装"
sudo apt-get update
check_success $? "更新软件包列表"

# 安装基础工具和 expect (用于自动化密码输入)
sudo apt-get install -y psmisc wget curl net-tools expect
check_success $? "安装基础工具 (psmisc, wget, curl, net-tools, expect)"

export DEBIAN_FRONTEND=noninteractive

echo -e "${YELLOW}重要提示: 请确保您已在云平台的防火墙/安全组中开放了 TCP 端口 8080。${NC}"
read -p "如果已确认，请按 Enter 键继续..."

# ==============================================================================
# == 第一部分：安装并运行 VNC 服务器 (桌面环境)
# ==============================================================================
print_step "步骤 1/5：安装 VNC 服务器和 XFCE 桌面"
sudo apt-get install -y tigervnc-standalone-server xfce4 xfce4-goodies terminator
check_success $? "安装 VNC 和 XFCE 核心组件"

print_info "正在自动设置一个安全的 VNC 密码..."
VNC_PASS=$(openssl rand -base64 8 | tr -d '/+=')
mkdir -p ~/.vnc

# 使用 expect 来可靠地设置密码
expect << EOF
spawn vncpasswd
expect "Password:"
send "${VNC_PASS}\r"
expect "Verify:"
send "${VNC_PASS}\r"
expect "Would you like to enter a view-only password (y/n)?"
send "n\r"
expect eof
EOF
check_success $? "使用 expect 自动设置 VNC 密码"
[ ! -f ~/.vnc/passwd ] && print_error "VNC 密码文件 (~/.vnc/passwd) 创建失败！"
print_success "VNC 密码已自动设置。"

print_info "正在创建优化的 VNC 启动脚本 (xstartup)..."
cat > ~/.vnc/xstartup << EOF
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP="XFCE"
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup
check_success $? "创建并配置优化的 xstartup 文件"

print_info "正在启动 VNC 服务器..."
# 先清理可能存在的旧会话
vncserver -kill :1 >/dev/null 2>&1
sleep 1
# 启动新的 VNC 服务器，允许所有 IP 连接
vncserver :1 -localhost no
check_success $? "启动 VNC 服务器 (:1)"

sleep 3
if ! pgrep -f "Xtigervnc :1" > /dev/null; then
    LOG_FILE_PATH=$(find ~/.vnc/ -name "*.log" | head -n 1)
    print_error "VNC 服务启动失败！未能检测到 'Xtigervnc :1' 进程。"
    [ -n "$LOG_FILE_PATH" ] && [ -f "$LOG_FILE_PATH" ] && print_info "最新日志内容:\n$(cat $LOG_FILE_PATH)"
    exit 1
fi
if ! netstat -tuln | grep -q ':5901'; then
    print_error "VNC 服务器端口 5901 未在监听。启动可能已失败。"
fi
print_success "VNC 服务器已在端口 5901 上成功运行并监听。"

# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/5：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
sudo apt-get install -y $GUACD_DEPS
check_success $? "安装 guacd 编译依赖项"

GUAC_VERSION="1.5.3" # 您可以更改为其他版本
print_info "正在下载 Guacamole Server v${GUAC_VERSION}..."
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
check_success $? "下载 Guacamole 源代码"
tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"
cd "guacamole-server-${GUAC_VERSION}"
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "执行 ./configure 脚本"
make
check_success $? "编译源代码 (make)"
sudo make install
check_success $? "安装编译好的文件 (make install)"
sudo ldconfig
check_success $? "更新动态链接库缓存"
cd ..

print_info "正在启动 guacd 服务..."
if [ -d /run/systemd/system ]; then
    print_info "检测到 systemd 环境，使用 systemctl 启动 guacd。"
    sudo systemctl enable guacd && sudo systemctl start guacd
    check_success $? "启动并设置 guacd 服务开机自启"
    sleep 2
    sudo systemctl is-active --quiet guacd
    check_success $? "确认 guacd 服务正在后台运行 (via systemctl)"
else
    print_warning "未检测到 systemd 环境。将直接启动 guacd 守护进程。"
    # 先杀掉旧进程，防止重复启动
    sudo pkill -f guacd
    sleep 1
    sudo /usr/local/sbin/guacd
    check_success $? "直接执行 guacd 命令"
fi

sleep 2
if ! pgrep guacd > /dev/null; then
    print_error "guacd 进程启动失败！"
fi
print_success "guacd 后端服务已成功启动。"


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/5：安装 Tomcat 并配置 Guacamole Web 应用"
print_info "正在安装 Java 和 Tomcat 9..."
sudo apt-get install -y default-jdk tomcat9
check_success $? "安装 default-jdk 和 tomcat9"

TOMCAT_SERVICE="tomcat9"
TOMCAT_WEBAPPS_DIR="/var/lib/tomcat9/webapps"
TOMCAT_USER="tomcat"

print_info "正在下载 Guacamole Web App (.war) v${GUAC_VERSION}..."
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
check_success $? "下载 guacamole.war 文件"

print_info "正在部署 guacamole.war 文件..."
sudo mv guacamole.war "${TOMCAT_WEBAPPS_DIR}/"
# 【关键修复】确保 .war 文件权限正确，Tomcat 才能解压它
sudo chown ${TOMCAT_USER}:${TOMCAT_USER} "${TOMCAT_WEBAPPS_DIR}/guacamole.war"
check_success $? "部署 .war 文件并设置正确的所有者"

print_info "正在创建 Guacamole 配置文件..."
GUAC_PASS="GuacAdmin2024!" # 设置一个更强的默认密码
sudo mkdir -p /etc/guacamole
sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml
auth-provider: net.sourceforge.guacamole.net.basic.BasicFileAuthenticationProvider
basic-user-mapping: /etc/guacamole/user-mapping.xml
EOF
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="guacadmin" password="${GUAC_PASS}">
        <connection name="XFCE Desktop via VNC">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">${VNC_PASS}</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建 guacamole.properties 和 user-mapping.xml"

print_info "正在设置 Guacamole 配置目录的权限..."
# 【关键修复】确保 Tomcat 用户可以读取配置文件
sudo chown -R ${TOMCAT_USER}:${TOMCAT_USER} /etc/guacamole
sudo chmod -R 750 /etc/guacamole
check_success $? "设置 /etc/guacamole 的所有者和权限"

# 【关键修复】为 Tomcat 创建 GUACAMOLE_HOME 链接
sudo ln -sfn /etc/guacamole /usr/share/tomcat9/.guacamole
check_success $? "创建 GUACAMOLE_HOME 符号链接"

print_info "正在重启 Tomcat 服务以加载 Guacamole..."
if [ -d /run/systemd/system ]; then
    sudo systemctl restart ${TOMCAT_SERVICE}
    check_success $? "重启 ${TOMCAT_SERVICE} 服务 (via systemctl)"
else
    print_warning "非 systemd 环境，正在手动重启 Tomcat..."
    sudo pkill -9 -f "org.apache.catalina.startup.Bootstrap" || true
    sleep 3
    sudo -u ${TOMCAT_USER} /usr/share/${TOMCAT_SERVICE}/bin/startup.sh
    check_success $? "手动启动 Tomcat 进程"
fi

# ==============================================================================
# == 第四部分：验证部署与自动修复
# ==============================================================================
print_step "步骤 4/5：验证 Guacamole Web 应用部署状态"
print_info "等待最多 60 秒，让 Tomcat 初始化 Guacamole 应用..."

SUCCESS=false
for i in {1..12}; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/guacamole/)
    if [ "$HTTP_CODE" -eq 200 ]; then
        print_success "验证成功！Guacamole 登录页面已在 /guacamole/ 上线 (HTTP 200)。"
        SUCCESS=true
        break
    else
        echo -n "."
        sleep 5
    fi
done

if [ "$SUCCESS" = false ]; then
    print_warning "在 /guacamole/ 路径验证失败 (最后状态码: $HTTP_CODE)。"
    print_info "正在尝试将 Guacamole 部署为 ROOT 应用 (通过根路径 / 访问)..."

    # 清理 webapps 目录
    sudo rm -rf "${TOMCAT_WEBAPPS_DIR}/ROOT"
    sudo cp "${TOMCAT_WEBAPPS_DIR}/guacamole.war" "${TOMCAT_WEBAPPS_DIR}/ROOT.war"
    check_success $? "将 guacamole.war 复制为 ROOT.war"

    print_info "再次重启 Tomcat 以加载 ROOT 应用..."
    if [ -d /run/systemd/system ]; then
        sudo systemctl restart ${TOMCAT_SERVICE}
    else
        sudo pkill -9 -f "org.apache.catalina.startup.Bootstrap" || true
        sleep 3
        sudo -u ${TOMCAT_USER} /usr/share/${TOMCAT_SERVICE}/bin/startup.sh
    fi
    check_success $? "重启 Tomcat 服务"

    print_info "等待最多 45 秒让 ROOT 应用初始化..."
    for i in {1..9}; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/)
        if [ "$HTTP_CODE" -eq 200 ]; then
            print_success "验证成功！Guacamole 已作为 ROOT 应用成功部署 (HTTP 200)。"
            SUCCESS=true
            break
        else
            echo -n "."
            sleep 5
        fi
    done
fi

if [ "$SUCCESS" = false ]; then
    print_error "所有自动部署尝试均失败。请查看下方的诊断信息进行手动排查。"
fi

# ==============================================================================
# == 第五部分：完成与诊断信息
# ==============================================================================
print_step "步骤 5/5：安装完成！"
print_success "Guacamole 环境已安装和配置完毕。"

echo -e "\n${BLUE}========================= 访问凭据 ==========================${NC}"
echo -e "  ${YELLOW}Guacamole URL: ${GREEN}http://<您的公网IP>:8080/${NC}"
echo -e "  ${YELLOW}用户名:          ${GREEN}guacadmin${NC}"
echo -e "  ${YELLOW}密码:            ${GREEN}${GUAC_PASS}${NC}"
echo -e "  ${YELLOW}(内部) VNC 密码: ${GREEN}${VNC_PASS}${NC} (已在 Guacamole 中自动配置)"
echo -e "${BLUE}=============================================================${NC}"

echo -e "\n${BLUE}======================= 诊断信息 ==========================${NC}"
# 1. 检查 guacd 进程
if pgrep guacd > /dev/null; then
    print_success "Guacamole 后端 (guacd) 正在运行。"
else
    print_error "Guacamole 后端 (guacd) 未运行！"
fi

# 2. 检查 VNC 进程和端口
if pgrep -f "Xtigervnc :1" > /dev/null && netstat -tuln | grep -q ':5901'; then
    print_success "VNC 服务器正在端口 5901 上运行。"
else
    print_error "VNC 服务器未在端口 5901 上运行！"
fi

# 3. 检查 Tomcat 进程和端口
if pgrep -f "org.apache.catalina.startup.Bootstrap" > /dev/null && netstat -tuln | grep -q ':8080'; then
    print_success "Tomcat 服务器正在端口 8080 上运行。"
else
    print_error "Tomcat 服务器未在端口 8080 上运行！"
fi

# 4. 检查 Tomcat webapps 目录
echo -e "\n${YELLOW}[i] Tomcat Web 应用目录 (${TOMCAT_WEBAPPS_DIR}) 内容:${NC}"
sudo ls -lA ${TOMCAT_WEBAPPS_DIR}/
echo -e "${YELLOW}-------------------------------------------------------------${NC}"
echo -e "${YELLOW}[i] 提示: 检查是否存在 'guacamole' 或 'ROOT' 目录。如果只有 .war 文件，说明解压失败。${NC}"

# 5. 显示关键日志文件路径
echo -e "\n${YELLOW}[i] 如遇问题，请检查以下关键日志文件:${NC}"
echo -e "  - Tomcat 日志:    ${GREEN}sudo tail -f /var/log/tomcat9/catalina.out${NC}"
echo -e "  - 系统服务日志:   ${GREEN}sudo journalctl -u ${TOMCAT_SERVICE} -f${NC} (仅限 systemd 环境)"
echo -e "  - Guacd 系统日志: ${GREEN}sudo journalctl -u guacd -f${NC} (仅限 systemd 环境)"
echo -e "  - VNC 日志:       ${GREEN}cat ~/.vnc/*.log${NC}"

echo -e "\n${GREEN}祝您使用愉快！${NC}"
