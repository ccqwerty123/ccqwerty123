#!/bin/bash

# ===================================================================================
# ==  Apache Guacamole 透明安装脚本 (v9.5 - 直接脚本重启)                       ==
# ===================================================================================
# ==  作者: Kilo Code (经 Gemini 修复与增强)                                      ==
# ==  此版本修正了在非 systemd 且无 init.d 脚本的环境下无法重启 Tomcat 的问题。 ==
# ==  现在脚本会回退到直接调用 Tomcat 自带的 startup.sh/shutdown.sh 脚本。      ==
# ===================================================================================

# --- 函数定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_step() { echo -e "\n${BLUE}=======================================================================\n== ${1}\n=======================================================================${NC}"; }
print_success() { echo -e "${GREEN}[✔] 成功: ${1}${NC}"; }
print_error() { echo -e "${RED}[✘] 失败: ${1}${NC}\n${RED}脚本已终止。请检查上面的错误信息并解决问题后重试。${NC}"; exit 1; }
print_info() { echo -e "${YELLOW}[i] 信息: ${1}${NC}"; }
print_warning() { echo -e "${YELLOW}[!] 警告: ${1}${NC}"; }

check_success() { [ $1 -eq 0 ] && print_success "${2}" || print_error "${2}"; }
# --- 函数定义结束 ---


# --- 脚本主流程开始 ---
print_step "步骤 0/4：环境准备"
sudo apt-get update
check_success $? "更新软件包列表"

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

print_info "正在自动生成并设置一个安全的 VNC 密码..."
VNC_PASS=$(openssl rand -base64 8)
mkdir -p ~/.vnc
echo -e "${VNC_PASS}\n${VNC_PASS}\nn" | vncpasswd
check_success $? "自动执行 vncpasswd 命令"
[ ! -f ~/.vnc/passwd ] && print_error "VNC 密码文件 (~/.vnc/passwd) 创建失败！"
print_success "VNC 密码已自动设置。"
echo -e "  ${YELLOW}您的 VNC 连接密码是: ${GREEN}${VNC_PASS}${NC} (此密码已自动配置，仅供记录)"

print_info "正在创建优化的 VNC 启动脚本 (xstartup)..."
cat > ~/.vnc/xstartup << EOF
#!/bin/sh
export XDG_CURRENT_DESKTOP="XFCE"
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
EOF
chmod +x ~/.vnc/xstartup
check_success $? "创建并配置优化的 xstartup 文件"

print_info "正在尝试首次启动 VNC 服务器以验证配置..."
vncserver :1 -xstartup ~/.vnc/xstartup
sleep 4
if ! pgrep -f "Xtigervnc :1" > /dev/null; then
    LOG_FILE_PATH=$(find ~/.vnc/ -name "*.log" | head -n 1)
    print_error "VNC 服务启动失败！未能检测到 'Xtigervnc :1' 进程。"
    [ -n "$LOG_FILE_PATH" ] && [ -f "$LOG_FILE_PATH" ] && print_info "日志内容:\n$(cat $LOG_FILE_PATH)"
    exit 1
fi
print_success "VNC 服务已成功临时启动。"
vncserver -kill :1 > /dev/null 2>&1 || pkill -f "Xtigervnc :1"
sleep 1
print_success "临时 VNC 会话已成功停止。"
print_info "正在以最终配置重新启动 VNC 服务器..."
vncserver -localhost no :1 -xstartup ~/.vnc/xstartup
check_success $? "以最终配置重新启动 VNC 服务器"
sleep 2
if ! netstat -tuln | grep -q ':5901'; then print_error "VNC 服务器端口 5901 未被监听。"; fi
print_success "VNC 服务器已在 :1 (端口 5901) 上成功运行并监听。"


# ==============================================================================
# == 第二部分：安装 guacd (Guacamole 后端)
# ==============================================================================
print_step "步骤 2/4：编译并安装 Guacamole 后端 (guacd)"
GUACD_DEPS="build-essential libcairo2-dev libjpeg-turbo8-dev libpng-dev libtool-bin libossp-uuid-dev libavcodec-dev libavutil-dev libswscale-dev freerdp2-dev libpango1.0-dev libssh2-1-dev libvncserver-dev libtelnet-dev libwebsockets-dev libpulse-dev"
sudo apt-get install -y $GUACD_DEPS
check_success $? "安装 guacd 编译依赖项"

GUAC_VERSION="1.5.3"
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/source/guacamole-server-${GUAC_VERSION}.tar.gz" -O guacamole-server.tar.gz
check_success $? "下载 Guacamole 源代码"
tar -xzf guacamole-server.tar.gz
check_success $? "解压源代码"
cd "guacamole-server-${GUAC_VERSION}"
./configure --with-systemd-dir=/etc/systemd/system
check_success $? "运行 ./configure 脚本"
make
check_success $? "编译源代码 (make)"
sudo make install
check_success $? "安装编译好的文件 (make install)"
sudo ldconfig
check_success $? "更新动态链接库缓存"

if [ -d /run/systemd/system ]; then
    print_info "检测到 systemd 环境，使用 systemctl 启动 guacd..."
    sudo systemctl enable guacd && sudo systemctl start guacd
    check_success $? "启动并设置 guacd 服务开机自启"
    sleep 2
    sudo systemctl is-active --quiet guacd
    check_success $? "确认 guacd 服务正在后台运行 (via systemctl)"
else
    print_warning "未检测到 systemd 环境。将直接启动 guacd 守护进程..."
    sudo /usr/local/sbin/guacd
    check_success $? "直接执行 guacd 命令"
    sleep 2
    pgrep guacd > /dev/null
    check_success $? "确认 guacd 进程正在后台运行 (via pgrep)"
fi
cd ..


# ==============================================================================
# == 第三部分：安装 Tomcat 和 Guacamole Web 应用 (前端)
# ==============================================================================
print_step "步骤 3/4：安装 Tomcat 并自动化配置 Guacamole"

TOMCAT_VERSION_MAJOR=""
TOMCAT_SERVICE=""
TOMCAT_WEBAPPS_DIR=""
print_info "正在尝试安装合适的 Tomcat 版本 (10, 9, 或 8)..."

if sudo apt-get install -y tomcat10 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="10"
elif sudo apt-get install -y tomcat9 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="9"
elif sudo apt-get install -y tomcat8 > /dev/null 2>&1; then
    TOMCAT_VERSION_MAJOR="8"
fi

if [ -n "$TOMCAT_VERSION_MAJOR" ]; then
    TOMCAT_SERVICE="tomcat${TOMCAT_VERSION_MAJOR}"
    TOMCAT_WEBAPPS_DIR="/var/lib/${TOMCAT_SERVICE}/webapps/"
    print_success "成功安装 Tomcat ${TOMCAT_VERSION_MAJOR}。"
else
    print_error "无法安装任何受支持的 Tomcat 版本 (10, 9, 8)。请检查您的 apt 软件源配置。"
fi

sudo mkdir -p /etc/guacamole && sudo chmod 755 /etc/guacamole
wget "https://dlcdn.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war" -O guacamole.war
sudo mv guacamole.war "${TOMCAT_WEBAPPS_DIR}"
check_success $? "部署 .war 文件到 ${TOMCAT_WEBAPPS_DIR}"

echo -e "${YELLOW}--- 自动化 Guacamole 密码配置 ---${NC}"
read -sp "请为 Guacamole 网页登录设置一个新密码 (这是您访问网页时用的): " GUAC_PASS; echo

sudo bash -c 'cat > /etc/guacamole/guacamole.properties' << EOF
guacd-hostname: localhost
guacd-port: 4822
user-mapping: /etc/guacamole/user-mapping.xml
EOF
sudo bash -c 'cat > /etc/guacamole/user-mapping.xml' << EOF
<user-mapping>
    <authorize username="user" password="${GUAC_PASS}">
        <connection name="XFCE Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">localhost</param>
            <param name="port">5901</param>
            <param name="password">${VNC_PASS}</param>
        </connection>
    </authorize>
</user-mapping>
EOF
check_success $? "创建并自动填入所有配置文件"
sudo chown tomcat:tomcat /etc/guacamole/ -R
check_success $? "设置配置文件权限"

# 【核心修正】在非 systemd 环境下，调用 Tomcat 自带的脚本进行重启
if [ -d /run/systemd/system ]; then
    sudo systemctl restart "${TOMCAT_SERVICE}"
    check_success $? "重启 ${TOMCAT_SERVICE} 服务 (via systemctl)"
else
    print_warning "非 systemd 环境，将通过 catalina.sh 脚本直接重启 Tomcat..."
    TOMCAT_BIN_DIR="/usr/share/${TOMCAT_SERVICE}/bin"

    if [ -f "${TOMCAT_BIN_DIR}/shutdown.sh" ] && [ -f "${TOMCAT_BIN_DIR}/startup.sh" ]; then
        print_info "正在执行 ${TOMCAT_BIN_DIR}/shutdown.sh..."
        sudo "${TOMCAT_BIN_DIR}/shutdown.sh" > /dev/null 2>&1
        sleep 5 # 等待进程关闭

        print_info "正在执行 ${TOMCAT_BIN_DIR}/startup.sh..."
        sudo "${TOMCAT_BIN_DIR}/startup.sh" > /dev/null 2>&1
        check_success $? "通过 catalina.sh 脚本启动 Tomcat"
    else
        print_error "找不到 Tomcat 的启动/关闭脚本 (在 ${TOMCAT_BIN_DIR} 中)。"
    fi
fi

echo "等待 25 秒让 Guacamole Web 应用完成初始化..."
sleep 25
HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" http://localhost:8080/guacamole/)
if [ "$HTTP_CODE" -eq 200 ]; then
    print_success "终极验证通过！Guacamole 登录页面已成功上线 (HTTP Code: $HTTP_CODE)。"
else
    print_error "终极验证失败！无法访问 Guacamole (HTTP Code: $HTTP_CODE)。请检查 Tomcat 日志: 'sudo cat /var/log/${TOMCAT_SERVICE}/catalina.*.log'"
fi

# ==============================================================================
# == 第四部分：完成
# ==============================================================================
print_step "步骤 4/4：安装完成！"
print_success "所有组件已成功安装并配置。"
echo -e "\n  访问地址: ${GREEN}http://<您的CloudStudio公网IP>:8080/guacamole/${NC}"
echo -e "  用户名:   ${GREEN}user${NC}"
echo -e "  密码:     ${GREEN}您刚刚为 Guacamole 设置的网页登录密码${NC}\n"
echo "祝您使用愉快！"
